import Foundation
import Testing
@testable import Stride

/// Covers `RaceBriefing` — the facts behind the race hub's race plan and what the model's
/// wording has to get past — and `AICoachService.writeRaceBriefing`.
struct RaceBriefingTests {

    // MARK: Fixtures

    private func plan(
        phase: RacePhase = .raceWeek(daysOut: 5),
        goalSeconds: TimeInterval = 12_600,
        predicted: TimeInterval? = 12_900,
        result: RaceResult? = nil
    ) -> RaceDayPlan {
        RaceDayPlan(
            raceName: "City Marathon",
            raceType: .marathon,
            distanceMeters: 42_195,
            raceDate: Date(timeIntervalSinceReferenceDate: 815_000_000),
            phase: phase,
            goals: goalSeconds > 0 ? RaceDayPlan.goals(forGoalSeconds: goalSeconds, distanceMeters: 42_195) : [],
            predictedFinishSeconds: predicted,
            taper: RaceTaperStatus(phase: .taper, weekNumber: 15, totalWeeks: 16, plannedKm: 32, peakKm: 64),
            result: result
        )
    }

    // MARK: Applies

    @Test func appliesOnlyToARaceStillToComeWithAGoal() {
        #expect(RaceBriefing.applies(to: plan()))
        #expect(RaceBriefing.applies(to: plan(phase: .building(daysOut: 40))))
        #expect(RaceBriefing.applies(to: plan(phase: .raceDay)))
        #expect(!RaceBriefing.applies(to: plan(phase: .finished(daysSince: 1))))
        #expect(!RaceBriefing.applies(to: plan(goalSeconds: 0)))
        let result = RaceResult(
            finishSeconds: 12_500, distanceMeters: 42_195, paceSecondsPerKm: 296,
            secondsInsideGoal: 100, tierAchieved: .a
        )
        #expect(!RaceBriefing.applies(to: plan(phase: .raceDay, result: result)))
    }

    // MARK: Prompt

    @Test func promptCarriesTheLadderPredictionAndTaper() {
        let prompt = RaceBriefing.prompt(for: plan(), unit: .metric)
        #expect(prompt.contains("Race: City Marathon"))
        #expect(prompt.contains("Distance: 42.2 km"))
        #expect(prompt.contains("When: race week, 5 days away"))
        #expect(prompt.contains("A goal: 3:30:00 at "))
        #expect(prompt.contains("B goal: 3:36:18 at "))
        #expect(prompt.contains("C goal: 3:44:42 at "))
        #expect(prompt.contains("Recent training predicts: 3:35:00"))
        #expect(prompt.contains("Prediction against the A goal: 5:00 slower than the A goal"))
        #expect(prompt.contains("Plan: Taper phase, week 15 of 16"))
        #expect(prompt.contains("This week's planned distance: 32.0 km"))
        #expect(prompt.contains("Below the biggest week of the plan by: 50%"))
    }

    @Test func promptSaysWhenThePredictionIsCloseOrMissing() {
        let close = RaceBriefing.prompt(for: plan(predicted: 12_630), unit: .metric)
        #expect(close.contains("Prediction against the A goal: about the same"))

        let missing = RaceBriefing.prompt(for: plan(predicted: nil), unit: .metric)
        #expect(missing.contains("not enough recent hard sessions to say"))
        #expect(!missing.contains("Prediction against the A goal"))
    }

    // MARK: Validation

    @Test func acceptsAPlanThatOnlyQuotesTheFacts() throws {
        let draft = RaceBriefingDraft(
            headline: "  Start at your B goal  ",
            pacing: "Your training says 3:35:00, so open at 3:36:18 pace and settle. Push only after halfway.",
            beforeTheRace: "Keep these 5 days easy and sleep well."
        )
        let wording = try #require(RaceBriefing.validated(draft, for: plan(), unit: .metric))
        #expect(wording.headline == "Start at your B goal")
        #expect(wording.source == RaceBriefing.prompt(for: plan(), unit: .metric))
    }

    @Test func rejectsAPlanWithItsOwnSplits() {
        let draft = RaceBriefingDraft(
            headline: "Even pace",
            pacing: "Reach halfway in 1:45:00 and hold on.",
            beforeTheRace: "Rest up."
        )
        #expect(RaceBriefing.validated(draft, for: plan(), unit: .metric) == nil)
    }

    @Test func rejectsBlankOrRunawayFields() {
        let blank = RaceBriefingDraft(headline: "Go", pacing: "  ", beforeTheRace: "Rest.")
        let runaway = RaceBriefingDraft(headline: "Go", pacing: "Steady.", beforeTheRace: String(repeating: "Rest. ", count: 50))
        #expect(RaceBriefing.validated(blank, for: plan(), unit: .metric) == nil)
        #expect(RaceBriefing.validated(runaway, for: plan(), unit: .metric) == nil)
    }

    // MARK: Service

    @Test func serviceReturnsTheCheckedPlanFromTheChosenModel() async {
        let recorder = BriefingRequestRecorder()
        let service = AICoachService(
            onDeviceBackend: BriefingWritingCoach(
                available: true,
                draft: RaceBriefingDraft(headline: "Start steady", pacing: "Open at 3:36:18 pace.", beforeTheRace: "Rest."),
                recorder: recorder
            )
        )

        let wording = await service.writeRaceBriefing(for: plan(), unit: .metric, provider: .applePrivateCloud)

        #expect(wording?.headline == "Start steady")
        let requests = await recorder.requests
        #expect(requests.map(\.useServerModel) == [true])
        #expect(requests.first?.instructions == RaceBriefing.instructions)
        #expect(requests.first?.prompt == RaceBriefing.prompt(for: plan(), unit: .metric))
    }

    @Test func serviceRetriesOnDeviceWhenTheDailyAllowanceIsUsedUp() async {
        let recorder = BriefingRequestRecorder()
        let service = AICoachService(
            onDeviceBackend: BriefingWritingCoach(
                available: true,
                draft: RaceBriefingDraft(headline: "Start steady", pacing: "Open easy.", beforeTheRace: "Rest."),
                recorder: recorder,
                serverError: .serverQuotaExceeded(resetDate: nil)
            )
        )
        let wording = await service.writeRaceBriefing(for: plan(), unit: .metric, provider: .applePrivateCloud)
        let requests = await recorder.requests
        #expect(requests.map(\.useServerModel) == [true, false])
        #expect(wording != nil)
    }

    @Test func serviceAsksNothingForAFinishedRace() async {
        let recorder = BriefingRequestRecorder()
        let service = AICoachService(
            onDeviceBackend: BriefingWritingCoach(
                available: true,
                draft: RaceBriefingDraft(headline: "Go", pacing: "Go.", beforeTheRace: "Go."),
                recorder: recorder
            )
        )
        let wording = await service.writeRaceBriefing(
            for: plan(phase: .finished(daysSince: 2)), unit: .metric, provider: .applePrivateCloud
        )
        let requests = await recorder.requests
        #expect(wording == nil)
        #expect(requests.isEmpty)
    }

    @Test func serviceGivesNothingWhenTheModelCannotHelp() async {
        let invented = RaceBriefingDraft(headline: "Go", pacing: "Run 4:40 per km.", beforeTheRace: "Rest.")
        let cases: [AICoachService] = [
            AICoachService(onDeviceBackend: nil),
            AICoachService(onDeviceBackend: BriefingWritingCoach(available: false, draft: invented, recorder: .init())),
            AICoachService(onDeviceBackend: BriefingWritingCoach(available: true, draft: nil, recorder: .init())),
            AICoachService(onDeviceBackend: BriefingWritingCoach(available: true, draft: invented, recorder: .init())),
        ]
        for service in cases {
            let wording = await service.writeRaceBriefing(for: plan(), unit: .metric, provider: .applePrivateCloud)
            #expect(wording == nil)
        }
    }

    @Test func storeRoundTripsTheLastWording() throws {
        let defaults = try #require(UserDefaults(suiteName: "RaceBriefingTests"))
        defaults.removePersistentDomain(forName: "RaceBriefingTests")
        let wording = RaceBriefingWording(headline: "H", pacing: "P", beforeTheRace: "B", source: "facts")
        #expect(RaceBriefingStore.load(from: defaults) == nil)
        RaceBriefingStore.save(wording, to: defaults)
        #expect(RaceBriefingStore.load(from: defaults) == wording)
    }
}

// MARK: - Fake backend

private actor BriefingRequestRecorder {
    struct Request: Sendable {
        let instructions: String
        let prompt: String
        let useServerModel: Bool
    }

    private(set) var requests: [Request] = []

    func record(_ request: Request) {
        requests.append(request)
    }
}

/// Writes a canned briefing, or throws when `draft` is nil, and records what it was asked.
/// `serverError`, when set, is what a request for the server model throws instead.
private struct BriefingWritingCoach: OnDeviceCoachGenerating {
    let available: Bool
    let draft: RaceBriefingDraft?
    let recorder: BriefingRequestRecorder
    var serverError: OnDeviceCoachError?

    func isAvailable() async -> Bool { available }
    func unavailableReason() async -> String? { available ? nil : "unavailable" }

    func generateRaceBriefing(
        instructions: String,
        prompt: String,
        useServerModel: Bool
    ) async throws -> RaceBriefingDraft {
        await recorder.record(.init(instructions: instructions, prompt: prompt, useServerModel: useServerModel))
        if useServerModel, let serverError { throw serverError }
        guard let draft else { throw OnDeviceCoachError.malformedResponse }
        return draft
    }

    func generateCoachInsight(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AICoachStructuredResponse {
        throw OnDeviceCoachError.unavailable
    }

    func generateWorkoutAdaptation(
        instructions: String,
        prompt: String,
        useServerModel: Bool
    ) async throws -> AIWorkoutAdaptationResponse {
        throw OnDeviceCoachError.unavailable
    }

    func generatePlanAdaptation(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AIWorkoutPlanAdaptationResponse {
        throw OnDeviceCoachError.unavailable
    }

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        throw OnDeviceCoachError.unavailable
    }
}
