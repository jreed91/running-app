#if canImport(FoundationModels)
import Foundation
import FoundationModels

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
        if useServerModel, #available(iOS 27.0, *) {
            // VERIFY-AGAINST-SDK (WWDC26 session 241): Private Cloud Compute model.
            let serverModel = PrivateCloudComputeLanguageModel()
            return LanguageModelSession(model: serverModel, instructions: instructions)
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
        #if STRIDE_ENABLE_IOS27_MODELS
        if useServerModel, #available(iOS 27.0, *) {
            // VERIFY-AGAINST-SDK: deeper reasoning for the server model.
            let response = try await session.respond(
                to: prompt,
                generating: type,
                options: GenerationOptions(reasoningLevel: .deep)
            )
            return response.content
        }
        #endif
        let response = try await session.respond(to: prompt, generating: type)
        return response.content
    }
}
#endif
