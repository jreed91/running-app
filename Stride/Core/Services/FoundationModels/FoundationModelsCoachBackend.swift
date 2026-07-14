#if canImport(FoundationModels)
import Foundation
import FoundationModels
#if canImport(Security)
import Security
#endif

/// On-device coach backend built on Apple's Foundation Models framework.
///
/// - Phase 1 (iOS 26): runs `SystemLanguageModel.default` with `@Generable` guided
///   generation. No API key, no network, data stays on device.
/// - Phase 2 (iOS 27): when built with `-D STRIDE_ENABLE_IOS27_MODELS` on the iOS 27
///   SDK, the heavier cases can be routed to Apple's Private Cloud Compute model
///   (larger context + deeper reasoning) while keeping the same privacy posture.
///
/// VERIFY-AGAINST-SDK: the symbol names below are taken from the WWDC25 (286/301) and
/// WWDC26 (241) sessions. Confirm exact signatures against the shipping SDK before
/// release — especially the streaming and Private Cloud Compute APIs, which are
/// beta-era. The Phase 2 path is compiled out by default for exactly this reason.
@available(iOS 26.0, *)
struct FoundationModelsCoachBackend: OnDeviceCoachGenerating {

    func isAvailable() async -> Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
    }

    func unavailableReason() async -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "On-device coaching needs a newer iPhone."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to enable on-device coaching."
        case .unavailable(.modelNotReady):
            return "Preparing on-device intelligence — try again shortly."
        case .unavailable:
            return "On-device coaching is unavailable right now."
        }
    }

    // MARK: - Generation

    func generateCoachInsight(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> AICoachStructuredResponse {
        let session = makeSession(instructions: instructions, useServerModel: useServerModel)
        let generated = try await respond(
            in: session,
            to: prompt,
            generating: GeneratedCoachInsight.self,
            useServerModel: useServerModel
        )
        // Single emission keeps the existing streaming UI buffer populated. Token-level
        // streaming via `session.streamResponse(to:generating:)` can be wired here once
        // the partial-snapshot API is verified on-device.
        onPartial(generated.summary)
        return generated.toStructuredResponse()
    }

    func generateWorkoutAdaptation(
        instructions: String,
        prompt: String,
        useServerModel: Bool
    ) async throws -> AIWorkoutAdaptationResponse {
        let session = makeSession(instructions: instructions, useServerModel: useServerModel)
        let generated = try await respond(
            in: session,
            to: prompt,
            generating: GeneratedWorkoutAdaptation.self,
            useServerModel: useServerModel
        )
        return generated.toAdaptationResponse()
    }

    func generatePlanAdaptation(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> AIWorkoutPlanAdaptationResponse {
        let session = makeSession(instructions: instructions, useServerModel: useServerModel)
        let generated = try await respond(
            in: session,
            to: prompt,
            generating: GeneratedPlanAdaptation.self,
            useServerModel: useServerModel
        )
        onPartial(generated.adaptations.first?.explanation ?? "")
        return generated.toPlanAdaptationResponse()
    }

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        useServerModel: Bool
    ) async throws -> String {
        let session = makeSession(instructions: instructions, useServerModel: useServerModel)
        // Replays the conversation as a single prompt to mirror the stateless cloud
        // contract (callers pass the full transcript each turn).
        let transcript = messages
            .map { "\($0.role == "assistant" ? "Coach" : "Runner"): \($0.content)" }
            .joined(separator: "\n")
        let prompt = """
        Runner context:
        \(context)

        Conversation so far:
        \(transcript)

        Reply as the coach to the runner's most recent message.
        """
        let response = try await session.respond(to: prompt)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OnDeviceCoachError.emptyResponse }
        return text
    }

    // MARK: - Session / model resolution

    private func makeSession(instructions: String, useServerModel: Bool) -> LanguageModelSession {
        #if STRIDE_ENABLE_IOS27_MODELS
        // Only route to Private Cloud Compute when this build actually holds the
        // required entitlement. Constructing `PrivateCloudComputeLanguageModel`
        // without it traps inside `Executor.assertEntitled()` — a fatal
        // `EXC_BREAKPOINT`, *not* a catchable Swift error — so a `do/catch` at the
        // call site cannot recover. We must gate the model *before* creating it and
        // fall back to the on-device model when the entitlement is absent.
        if useServerModel, #available(iOS 27.0, *), Self.hasPrivateCloudComputeEntitlement {
            // VERIFY-AGAINST-SDK (WWDC26 session 241): Private Cloud Compute model.
            let serverModel = PrivateCloudComputeLanguageModel()
            return LanguageModelSession(model: serverModel, instructions: instructions)
        }
        #endif
        return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
    }

    #if STRIDE_ENABLE_IOS27_MODELS
    /// Whether this build carries an entitlement that authorises Apple's Private
    /// Cloud Compute language model. The check is deliberately *fail-safe*: an
    /// absent, unknown, or unreadable entitlement routes coaching to the on-device
    /// model (the correct non-crashing behaviour) rather than trapping.
    ///
    /// VERIFY-AGAINST-SDK: confirm the exact entitlement key(s) against the shipping
    /// SDK. Because a missing key falls back to on-device, an out-of-date key here is
    /// safe — it can only under-enable PCC, never crash.
    private static let hasPrivateCloudComputeEntitlement: Bool = {
        #if targetEnvironment(simulator)
        // PCC is not available in the simulator; never attempt it there.
        return false
        #elseif canImport(Security)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let candidateKeys = [
            "com.apple.developer.foundation-models.private-cloud-compute",
            "com.apple.developer.foundation-models"
        ]
        for key in candidateKeys {
            guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { continue }
            if let flag = value as? Bool {
                if flag { return true }
            } else {
                // Any non-boolean value (e.g. an array of allowed modes) counts as present.
                return true
            }
        }
        return false
        #else
        return false
        #endif
    }()
    #endif

    private func respond<Content>(
        in session: LanguageModelSession,
        to prompt: String,
        generating type: Content.Type,
        useServerModel: Bool
    ) async throws -> Content where Content: Generable {
        // The on-device vs. Private Cloud Compute choice is made in `makeSession`
        // (which model backs the session); the response call itself is identical for
        // both, so `useServerModel` is only meaningful there.
        _ = useServerModel
        let response = try await session.respond(to: prompt, generating: type)
        return response.content
    }
}
#endif
