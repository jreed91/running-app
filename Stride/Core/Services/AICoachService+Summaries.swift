import Foundation

// Apple Intelligence write-ups built from facts the app computed: the Progress tab's
// week in review and the race hub's race plan. Each asks the runner's chosen model,
// retries on-device when the daily Private Cloud Compute allowance is used up, and
// returns only wording that passed its own number check — see `WeekReview` and
// `RaceBriefing`.

extension AICoachService {

    /// The model's review of the week in `facts`, checked against them; nil when there is
    /// no model, the request fails, or the draft carries a number the facts do not, which
    /// leaves the Progress card on its own plain sentence. See `WeekReview`.
    ///
    /// Follows the runner's model choice and retries on-device once the daily Private
    /// Cloud Compute allowance is used up, as the Coach Tips do and for the same reason:
    /// nobody pressed a button for this, so there is no one waiting to be told.
    func writeWeekReview(
        for facts: WeekReviewFacts,
        unit: UnitPreference,
        provider: AIProvider
    ) async -> WeekReviewWording? {
        guard let backend = onDeviceBackend, await backend.isAvailable() else { return nil }
        let prompt = WeekReview.prompt(for: facts, unit: unit)
        do {
            let draft: WeekReviewDraft
            do {
                draft = try await backend.generateWeekReview(
                    instructions: WeekReview.instructions,
                    prompt: prompt,
                    useServerModel: provider.usesPrivateCloudCompute
                )
            } catch OnDeviceCoachError.serverQuotaExceeded(_) {
                draft = try await backend.generateWeekReview(
                    instructions: WeekReview.instructions,
                    prompt: prompt,
                    useServerModel: false
                )
            }
            return WeekReview.validated(draft, for: facts, unit: unit)
        } catch {
            return nil
        }
    }

    /// The model's race plan for `plan`, checked against its facts; nil when there is no
    /// model, the request fails, or the draft carries a number the facts do not, which
    /// leaves the race hub without the card. See `RaceBriefing`.
    ///
    /// Same model choice and quota fallback as `writeWeekReview(for:unit:provider:)`.
    func writeRaceBriefing(
        for plan: RaceDayPlan,
        unit: UnitPreference,
        provider: AIProvider
    ) async -> RaceBriefingWording? {
        guard RaceBriefing.applies(to: plan),
              let backend = onDeviceBackend, await backend.isAvailable() else { return nil }
        let prompt = RaceBriefing.prompt(for: plan, unit: unit)
        do {
            let draft: RaceBriefingDraft
            do {
                draft = try await backend.generateRaceBriefing(
                    instructions: RaceBriefing.instructions,
                    prompt: prompt,
                    useServerModel: provider.usesPrivateCloudCompute
                )
            } catch OnDeviceCoachError.serverQuotaExceeded(_) {
                draft = try await backend.generateRaceBriefing(
                    instructions: RaceBriefing.instructions,
                    prompt: prompt,
                    useServerModel: false
                )
            }
            return RaceBriefing.validated(draft, for: plan, unit: unit)
        } catch {
            return nil
        }
    }
}
