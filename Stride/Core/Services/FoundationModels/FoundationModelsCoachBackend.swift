#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Coach backend built on Apple's Foundation Models framework.
///
/// Two models sit behind one API. `SystemLanguageModel.default` runs on-device: always
/// available, no network, ~8K context. `PrivateCloudComputeLanguageModel` (iOS 27+) runs
/// Apple's server-side model on Private Cloud Compute: 32K context and stronger reasoning,
/// still keyless and still private. Which one a request uses is the runner's setting
/// (`AIProvider`), and `applePrivateCloud` is the default — see `AppSettings`.
///
/// Both models conform to `LanguageModel`, so the session, the `@Generable` schemas, the
/// instructions and every downstream mapping are shared; only `makeSession` differs.
///
/// PCC needs the `com.apple.developer.private-cloud-compute` entitlement (declared in
/// `project.yml`) *and* a network connection, so every server request is gated on
/// `PrivateCloudComputeLanguageModel.availability` and falls back to the on-device model
/// when PCC can't serve it. The one failure that is *not* silently downgraded is the daily
/// quota: Apple asks apps to tell the runner about it and offer the upgrade flow instead.
///
/// Annotated iOS 27 because `PrivateCloudComputeLanguageModel` and `ContextOptions` are
/// iOS 27 symbols. That is not a restriction in practice — every target in `project.yml`
/// already deploys to 27.0 — so the PCC path needs no `#available` guard and the only
/// gating left is the *runtime* kind (`availability`), which is the gate that matters.
@available(iOS 27.0, *)
struct FoundationModelsCoachBackend: OnDeviceCoachGenerating {

    // MARK: - Availability

    func isAvailable() async -> Bool {
        if onDeviceAvailability == .available { return true }
        // PCC can serve a request even while the on-device model is still downloading.
        return PrivateCloudComputeLanguageModel().availability == .available
    }

    func unavailableReason() async -> String? {
        switch onDeviceAvailability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "AI coaching needs a newer iPhone."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to enable AI coaching."
        case .unavailable(.modelNotReady):
            // PCC does not wait on the on-device download, so this is only a blocker
            // when the server model is out of reach too.
            if PrivateCloudComputeLanguageModel().availability == .available { return nil }
            return "Preparing on-device intelligence — try again shortly."
        case .unavailable:
            return "AI coaching is unavailable right now."
        }
    }

    func serverModelStatus() async -> ServerModelStatus? {
        let model = PrivateCloudComputeLanguageModel()

        let availability: ServerModelStatus.Availability
        switch model.availability {
        case .available:
            availability = .available
        case .unavailable(.deviceNotEligible):
            availability = .deviceNotEligible
        case .unavailable(.systemNotReady):
            availability = .systemNotReady
        case .unavailable:
            // `UnavailableReason` can grow; an unrecognised reason is still "no PCC".
            availability = .unknownReason
        }

        let usage = model.quotaUsage
        let quota: ServerModelStatus.Quota
        if case .belowLimit(let info) = usage.status {
            quota = .belowLimit(approachingLimit: info.isApproachingLimit)
        } else {
            quota = .limitReached
        }

        return ServerModelStatus(
            availability: availability,
            quota: quota,
            resetDate: usage.resetDate,
            canRequestLimitIncrease: usage.limitIncreaseSuggestion != nil
        )
    }

    @MainActor
    func presentLimitIncrease() {
        // Re-read the suggestion rather than caching one: it is the system's offer, and it
        // goes away the moment the runner's quota refreshes or they upgrade.
        PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion?.show()
    }

    private var onDeviceAvailability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    // MARK: - Generation

    func generateCoachInsight(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> AICoachStructuredResponse {
        let generated = try await generate(
            instructions: instructions,
            prompt: prompt,
            generating: GeneratedCoachInsight.self,
            useServerModel: useServerModel,
            reasoning: .moderate
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
        let generated = try await generate(
            instructions: instructions,
            prompt: prompt,
            generating: GeneratedWorkoutAdaptation.self,
            useServerModel: useServerModel,
            reasoning: .moderate
        )
        return generated.toAdaptationResponse()
    }

    func generatePlanAdaptation(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> AIWorkoutPlanAdaptationResponse {
        let generated = try await generate(
            instructions: instructions,
            prompt: prompt,
            generating: GeneratedPlanAdaptation.self,
            useServerModel: useServerModel,
            // Re-planning weighs a whole block of training against competing constraints —
            // the case Apple calls out for deep reasoning.
            reasoning: .deep
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

        let text = try await withServerFallback(
            instructions: instructions,
            useServerModel: useServerModel,
            // Chat is a back-and-forth a runner is waiting on, so buy latency over depth.
            reasoning: .light
        ) { session, reasoning in
            let response: LanguageModelSession.Response<String>
            if let reasoning {
                response = try await session.respond(
                    to: prompt,
                    contextOptions: ContextOptions(reasoningLevel: reasoning)
                )
            } else {
                response = try await session.respond(to: prompt)
            }
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { throw OnDeviceCoachError.emptyResponse }
        return text
    }

    // MARK: - Session / model resolution

    /// Runs `work` against a session on the Private Cloud Compute model when the runner
    /// asked for it and PCC can serve the request, otherwise against the on-device model.
    ///
    /// Apple's guidance is to retry on-device when a PCC request fails for a reason that
    /// says nothing about the prompt — no network, or the service being busy. Reaching the
    /// daily quota is different: the runner has to wait for the refresh or upgrade, so that
    /// one surfaces as `OnDeviceCoachError.serverQuotaExceeded` for the UI to explain.
    ///
    /// The session is built here, where each model's *concrete* type is still in hand:
    /// `LanguageModelSession.init(model:tools:instructions:)` takes `some LanguageModel`,
    /// so handing it an `any LanguageModel` would lean on implicit existential opening for
    /// no benefit. `work` receives a reasoning level only on the server path — the
    /// on-device call stays byte-for-byte what it was, so this change cannot move
    /// on-device behaviour.
    private func withServerFallback<T>(
        instructions: String,
        useServerModel: Bool,
        reasoning: ContextOptions.ReasoningLevel,
        _ work: (LanguageModelSession, ContextOptions.ReasoningLevel?) async throws -> T
    ) async throws -> T {
        if useServerModel {
            let model = PrivateCloudComputeLanguageModel()
            if model.availability == .available {
                do {
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    return try await work(session, reasoning)
                } catch let error as PrivateCloudComputeLanguageModel.Error {
                    switch error {
                    case .quotaLimitReached:
                        // Read the refresh date off the model rather than the error payload:
                        // it is the same value and one less shape to guess at.
                        throw OnDeviceCoachError.serverQuotaExceeded(
                            resetDate: model.quotaUsage.resetDate
                        )
                    case .networkFailure, .serviceUnavailable:
                        break  // Fall through to the on-device model below.
                    @unknown default:
                        break  // A new PCC failure mode is still worth an on-device answer.
                    }
                }
            }
        }
        guard onDeviceAvailability == .available else { throw OnDeviceCoachError.unavailable }
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: instructions
        )
        return try await work(session, nil)
    }

    private func generate<Content>(
        instructions: String,
        prompt: String,
        generating type: Content.Type,
        useServerModel: Bool,
        reasoning: ContextOptions.ReasoningLevel
    ) async throws -> Content where Content: Generable {
        try await withServerFallback(
            instructions: instructions,
            useServerModel: useServerModel,
            reasoning: reasoning
        ) { session, reasoning in
            let response: LanguageModelSession.Response<Content>
            if let reasoning {
                response = try await session.respond(
                    to: prompt,
                    generating: type,
                    // The `contextOptions` overload drops the standalone
                    // `includeSchemaInPrompt` argument, and its default is `true` — keep
                    // that, or guided generation loses the schema bias.
                    contextOptions: ContextOptions(
                        includeSchemaInPrompt: true,
                        reasoningLevel: reasoning
                    )
                )
            } else {
                response = try await session.respond(to: prompt, generating: type)
            }
            return response.content
        }
    }
}
#endif
