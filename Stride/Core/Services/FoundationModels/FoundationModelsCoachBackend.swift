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
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AICoachStructuredResponse {
        let generated = try await streamGenerate(
            instructions: instructions,
            prompt: prompt,
            generating: GeneratedCoachInsight.self,
            useServerModel: useServerModel,
            reasoning: .moderate,
            // `summary` is the field the run-summary preview card renders, and guided
            // generation fills the fields in declaration order, so it lands early —
            // `headline` is the only thing ahead of it.
            // Every field of a partially generated value is optional until it is
            // written, so an unwritten summary is an empty preview, not a nil one.
            partialText: { $0.summary ?? "" },
            onPartialText: onPartialText
        )
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
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AIWorkoutPlanAdaptationResponse {
        let generated = try await streamGenerate(
            instructions: instructions,
            prompt: prompt,
            generating: GeneratedPlanAdaptation.self,
            useServerModel: useServerModel,
            // Re-planning weighs a whole block of training against competing constraints —
            // the case Apple calls out for deep reasoning.
            reasoning: .deep,
            // Smart Adapt lists the coach's reasoning a workout at a time, so every
            // explanation finished so far goes out, one per line. An element of a
            // partially generated array is itself partially generated, so the newest
            // one has no `explanation` until it is written — and that is exactly the
            // half-finished line Smart Adapt should not be showing yet.
            partialText: { partial in
                (partial.adaptations ?? [])
                    .compactMap(\.explanation)
                    .joined(separator: "\n")
            },
            onPartialText: onPartialText
        )
        return generated.toPlanAdaptationResponse()
    }

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
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
            prompt: prompt,
            useServerModel: useServerModel,
            // Chat is a back-and-forth a runner is waiting on, so buy latency over depth.
            reasoning: .light
        ) { session, reasoning, prompt in
            // A plain-text stream yields the reply aggregated so far, which is what the
            // chat bubble wants, so there is nothing to accumulate here.
            let stream: LanguageModelSession.ResponseStream<String>
            if let reasoning {
                stream = session.streamResponse(
                    to: prompt,
                    contextOptions: ContextOptions(reasoningLevel: reasoning)
                )
            } else {
                stream = session.streamResponse(to: prompt)
            }

            var latest = ""
            for try await snapshot in stream {
                latest = snapshot.content
                // Awaited, not fired off in a detached `Task`: the update has to land
                // before the next snapshot is pulled, or SwiftUI coalesces the lot of
                // them into one render and the reply appears in a single jump.
                await onPartialText(latest.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return latest.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { throw OnDeviceCoachError.emptyResponse }
        return text
    }

    func generateCoachTips(
        instructions: String,
        prompt: String,
        useServerModel: Bool
    ) async throws -> [CoachTipDraft] {
        let generated = try await generate(
            instructions: instructions,
            prompt: prompt,
            generating: GeneratedCoachTips.self,
            useServerModel: useServerModel,
            // Rewording three short cards needs no deliberation, and the Home tab is
            // already showing the hard-coded copy while this runs. Only read on the
            // Private Cloud Compute path, like every other reasoning level here.
            reasoning: .light
        )
        return generated.toDrafts()
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
    ///
    /// The prompt handed to `work` is the *fitted* one. Which model is serving the request
    /// is only settled here, and the two windows differ by a factor of four (~8K on-device
    /// against PCC's ~32K), so a prompt can only be measured once its model is chosen —
    /// and a request that falls back from PCC to on-device is re-fitted for the smaller
    /// window on the way.
    ///
    /// A fallback that happens *mid-stream* runs `work` twice, so the partials the first
    /// attempt published are followed by the on-device model's own, starting again from
    /// nothing. That reads correctly on screen precisely because partials are cumulative:
    /// the preview resets and regrows rather than splicing two models' sentences together.
    private func withServerFallback<T>(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        reasoning: ContextOptions.ReasoningLevel,
        _ work: (LanguageModelSession, ContextOptions.ReasoningLevel?, String) async throws -> T
    ) async throws -> T {
        if useServerModel {
            let model = PrivateCloudComputeLanguageModel()
            if model.availability == .available {
                do {
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    // `try? await` rather than a plain read: PCC's `contextSize` is the
                    // asynchronous one of the two. `try` and `await` on an expression that
                    // turns out to need neither are warnings, not errors.
                    let contextSize = try? await model.contextSize
                    let fitted = fittedPrompt(prompt, instructions: instructions, contextSize: contextSize)
                    return try await work(session, reasoning, fitted)
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
        let model = SystemLanguageModel.default
        let session = LanguageModelSession(model: model, instructions: instructions)
        // `SystemLanguageModel.contextSize` is a plain `Int` getter — no `await`, no
        // `try`. The two models genuinely differ here, which is half of why this cannot
        // be written once against `some LanguageModel`.
        let fitted = fittedPrompt(prompt, instructions: instructions, contextSize: model.contextSize)
        return try await work(session, nil, fitted)
    }

    /// Streams a guided generation, publishing text from each partial snapshot and
    /// returning the finished value.
    ///
    /// The final value is rebuilt from the last snapshot's `rawContent` rather than by
    /// collecting the stream a second time: `ResponseStream` is a single-pass sequence,
    /// so `collect()` and a `for try await` loop are two ways of consuming the same
    /// stream, not two things to do to one. `Content(_: GeneratedContent)` is the
    /// `Generable` requirement that turns that raw content back into the typed value,
    /// and it throws when the stream ended mid-structure — which is a malformed
    /// response, and lands on `AICoachService`'s local-heuristic fallback.
    private func streamGenerate<Content>(
        instructions: String,
        prompt: String,
        generating type: Content.Type,
        useServerModel: Bool,
        reasoning: ContextOptions.ReasoningLevel,
        partialText: @escaping @Sendable (Content.PartiallyGenerated) -> String,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> Content where Content: Generable {
        try await withServerFallback(
            instructions: instructions,
            prompt: prompt,
            useServerModel: useServerModel,
            reasoning: reasoning
        ) { session, reasoning, prompt in
            let stream: LanguageModelSession.ResponseStream<Content>
            if let reasoning {
                stream = session.streamResponse(
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
                stream = session.streamResponse(to: prompt, generating: type)
            }

            var lastRawContent: GeneratedContent?
            var lastPublished = ""
            for try await snapshot in stream {
                lastRawContent = snapshot.rawContent
                let text = partialText(snapshot.content)
                // A snapshot arrives per token, and most of them add nothing to the one
                // field being shown. Publishing only on a change keeps the UI off the
                // main actor for the other ninety-odd percent of them.
                if text != lastPublished {
                    lastPublished = text
                    // See the note in `generateChatReply`: awaited so each update gets
                    // its own render pass.
                    await onPartialText(text)
                }
            }

            guard let lastRawContent else { throw OnDeviceCoachError.emptyResponse }
            do {
                return try Content(lastRawContent)
            } catch {
                throw OnDeviceCoachError.malformedResponse
            }
        }
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
            prompt: prompt,
            useServerModel: useServerModel,
            reasoning: reasoning
        ) { session, reasoning, prompt in
            let response: LanguageModelSession.Response<Content>
            if let reasoning {
                response = try await session.respond(
                    to: prompt,
                    generating: type,
                    // See the note in `streamGenerate`: this overload defaults
                    // `includeSchemaInPrompt` to `true` and drops the standalone argument.
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

    // MARK: - Context-window pre-flight

    /// Fraction of a model's context window held back for the response, the guided
    /// generation schema, and the instructions' own share of the session.
    ///
    /// The window covers input *and* output (Apple's `contextSize` is the total), and a
    /// coach insight is a headline, a summary, an analysis paragraph, four evidence chips
    /// and three action items — comfortably the largest output of the four features. A
    /// quarter of an 8K on-device window is ~2K tokens of headroom, which is generous for
    /// that and cheap in what it costs the prompt.
    private static let responseHeadroomFraction = 4

    /// `prompt`, shortened until it fits `contextSize`, or unchanged when it already fits
    /// or when the model did not report a window.
    ///
    /// `contextSize` is read by the caller, where the model's concrete type is still in
    /// hand. It has to be: `contextSize` is a plain `Int` on `SystemLanguageModel` and
    /// asynchronous on `PrivateCloudComputeLanguageModel`, and neither is a member of the
    /// `LanguageModel` protocol — an earlier version of this took `some LanguageModel` and
    /// failed to compile on exactly that ("has no member 'contextSize'").
    ///
    /// The prompt's size is **estimated** rather than measured; see
    /// `CoachPromptBudget.estimatedTokenCount(of:)` for why, and what it would take to go
    /// back to the real count. The estimate runs high, so this trims a little sooner than
    /// it strictly must — which is the harmless direction, since what it drops is the
    /// oldest run in the history block.
    ///
    /// Not being able to size the window at all is not an error worth surfacing: the
    /// prompt that would have been sent before this existed is still the prompt sent now,
    /// and a genuinely oversized one fails the same way it failed before — as a thrown
    /// error that `AICoachService` turns into the locally-computed insight. This can only
    /// improve on that, never replace it.
    private func fittedPrompt(
        _ prompt: String,
        instructions: String,
        contextSize: Int?
    ) -> String {
        guard let contextSize, contextSize > 0 else { return prompt }
        let budget = contextSize
            - contextSize / Self.responseHeadroomFraction
            - CoachPromptBudget.estimatedTokenCount(of: instructions)
        guard budget > 0 else { return prompt }

        var fitted = prompt
        // Bounded by the row count rather than by `while true`: each pass drops exactly
        // one row, so this cannot outlive the history block.
        for _ in 0..<CoachPromptBudget.historyRowCount(in: prompt) {
            guard CoachPromptBudget.estimatedTokenCount(of: fitted) > budget else { return fitted }
            guard let trimmed = CoachPromptBudget.droppingOldestHistoryRow(from: fitted) else {
                // Nothing left that is safe to drop. Send it: an oversized prompt that
                // the model rejects is still a better outcome than one silently gutted
                // of the workout ids the response is keyed on.
                return fitted
            }
            fitted = trimmed
        }
        return fitted
    }
}
#endif
