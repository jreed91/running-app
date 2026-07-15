#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// On-device coach backend built on Apple's Foundation Models framework.
///
/// - Phase 1 (iOS 26): runs `SystemLanguageModel.default` with `@Generable` guided
///   generation. No API key, no network, data stays on device.
/// - Phase 2 (iOS 27): when built with `-D STRIDE_ENABLE_IOS27_MODELS`, the heavier
///   cases can be routed to Apple's Private Cloud Compute model (larger context +
///   deeper reasoning) while keeping the same privacy posture.
///
/// VERIFY-AGAINST-SDK: the Phase 2 symbol names below are taken from the WWDC26 (319)
/// session and DO NOT exist in the shipping iOS 27 SDK — defining
/// `STRIDE_ENABLE_IOS27_MODELS` currently fails to compile with
/// "Cannot find 'PrivateCloudComputeLanguageModel' in scope". The flag must stay
/// undefined (see project.yml) until the PCC API ships and the names are confirmed.
/// Until then `useServerModel` safely falls through to the on-device model.
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
        if useServerModel, #available(iOS 27.0, *) {
            // VERIFY-AGAINST-SDK (WWDC26 session 319): Private Cloud Compute model.
            //
            // Constructing the model is safe, but running inference without the
            // Private Cloud Compute entitlement traps inside
            // `Executor.assertEntitled()` — a fatal `EXC_BREAKPOINT`, *not* a
            // catchable Swift error, so a `do/catch` at the call site cannot recover.
            // Gate on the framework's own `isAvailable` (which reflects the
            // entitlement, device eligibility, and Apple Intelligence being on) and
            // fall back to the on-device model when PCC can't be used.
            let serverModel = PrivateCloudComputeLanguageModel()
            if serverModel.isAvailable {
                return LanguageModelSession(model: serverModel, instructions: instructions)
            }
        }
        #endif
        return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
    }

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
