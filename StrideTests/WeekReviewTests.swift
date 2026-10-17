import Foundation
import Testing
@testable import Stride

/// Covers `WeekReview` — the facts behind the Progress tab's week card and what the
/// model's wording of them has to get past — and `AICoachService.writeWeekReview`.
///
/// The number check is the one that matters: the card's figures are the app's, and a
/// review may quote them but never make up one of its own.
struct WeekReviewTests {

    // MARK: Fixtures

    /// Thursday 15 October 2026, midday.
    private let now: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 15; components.hour = 12
        return Calendar.current.date(from: components)!
    }()

    private var monday: Date { now.startOfWeek }

    private func day(_ offset: Int, hour: Int = 7) -> Date {
        Calendar.current.date(byAdding: .hour, value: offset * 24 + hour, to: monday)!
    }

    private func run(_ dayOffset: Int, km: Double, type: WorkoutType = .easy, feel: RunFeel? = nil) -> RunWorkout {
        let workout = RunWorkout(
            date: day(dayOffset),
            distanceMeters: km * 1_000,
            durationSeconds: km * 330,
            workoutType: type
        )
        workout.feel = feel
        return workout
    }

    private func session(_ dayOffset: Int, km: Double, type: WorkoutType = .easy, done: Bool) -> ScheduledWorkout {
        let workout = ScheduledWorkout(scheduledDate: day(dayOffset), workoutType: type, targetDistanceMeters: km * 1_000)
        workout.isCompleted = done
        return workout
    }

    // MARK: Facts

    @Test func reviewsThisWeekOnceItHasARun() throws {
        let runs = [run(0, km: 8), run(2, km: 6, type: .tempo, feel: .hard)]
        let facts = try #require(WeekReview.facts(runs: runs, scheduled: [], now: now))

        #expect(facts.isCurrentWeek)
        #expect(facts.daysLeft == 3)
        #expect(facts.runCount == 2)
        #expect(facts.totalMeters == 14_000)
        #expect(facts.longestRunMeters == 8_000)
        #expect(facts.keySessions == [.tempo])
        #expect(facts.averageFeel == .hard)
        #expect(!facts.hasPlan)
    }

    @Test func fallsBackToLastWeekAndThenToNothing() throws {
        let lastWeek = [run(-6, km: 10), run(-4, km: 5)]
        let facts = try #require(WeekReview.facts(runs: lastWeek, scheduled: [], now: now))
        #expect(!facts.isCurrentWeek)
        #expect(facts.daysLeft == 0)
        #expect(facts.runCount == 2)

        #expect(WeekReview.facts(runs: [run(-20, km: 10)], scheduled: [], now: now) == nil)
    }

    @Test func ignoresWalksAndCrossTraining() {
        let runs = [run(0, km: 4, type: .walk), run(1, km: 20, type: .crossTraining)]
        #expect(WeekReview.facts(runs: runs, scheduled: [], now: now) == nil)
    }

    @Test func countsThePlansRunSessionsOnly() throws {
        let scheduled = [
            session(0, km: 8, done: true),
            session(2, km: 6, type: .tempo, done: true),
            session(3, km: 0, type: .rest, done: false),
            session(4, km: 0, type: .strength, done: false),
            session(5, km: 16, type: .longRun, done: false),
            session(10, km: 8, done: false),  // next week
        ]
        let facts = try #require(
            WeekReview.facts(runs: [run(0, km: 8), run(2, km: 6, type: .tempo)], scheduled: scheduled, now: now)
        )
        #expect(facts.plannedSessions == 3)
        #expect(facts.completedSessions == 2)
        #expect(facts.upcomingSessions == 1)
        #expect(facts.plannedMeters == 30_000)
        #expect(facts.percentOfPlan == 47)
    }

    @Test func flagsEasyRunsThatFeltHard() throws {
        let runs = [run(0, km: 8, feel: .veryHard), run(1, km: 8, feel: .hard), run(2, km: 6, type: .interval, feel: .hard)]
        let facts = try #require(WeekReview.facts(runs: runs, scheduled: [], now: now))
        #expect(facts.easyRunsFeltHard == 2)
    }

    @Test func usualWeekNeedsTwoActiveWeeksAndCountsEmptyOnes() {
        let oneWeek = [run(-7, km: 20)]
        #expect(WeekReview.usualWeeklyMeters(before: monday, runs: oneWeek) == nil)

        let twoWeeks = [run(-7, km: 20), run(-21, km: 20)]
        #expect(WeekReview.usualWeeklyMeters(before: monday, runs: twoWeeks) == 10_000)
    }

    // MARK: Plain copy and prompt

    @Test func plainCopyComparesAgainstThePlanFirst() throws {
        let scheduled = [session(0, km: 10, done: true), session(2, km: 10, done: false)]
        let facts = try #require(WeekReview.facts(runs: [run(0, km: 10)], scheduled: scheduled, now: now))
        #expect(WeekReview.plainHeadline(for: facts, unit: .metric) == "1 run · 10.0 km")
        #expect(WeekReview.plainSummary(for: facts, unit: .metric) == "50% of the 20.0 km planned, 1 of 2 sessions done.")
    }

    @Test func promptCarriesTheFactsInTheRunnersUnit() throws {
        let facts = try #require(WeekReview.facts(runs: [run(0, km: 8), run(2, km: 6, type: .tempo)], scheduled: [], now: now))
        let prompt = WeekReview.prompt(for: facts, unit: .metric)
        #expect(prompt.contains("this week, still under way, 3 days left"))
        #expect(prompt.contains("Distance: 14.0 km"))
        #expect(prompt.contains("Harder sessions: Tempo"))
        #expect(prompt.contains("Training plan: none"))
        #expect(WeekReview.prompt(for: facts, unit: .imperial).contains("Distance: 8.7 mi"))
    }

    // MARK: Validation

    private func sampleFacts() throws -> WeekReviewFacts {
        try #require(WeekReview.facts(runs: [run(0, km: 8), run(2, km: 6, type: .tempo)], scheduled: [], now: now))
    }

    @Test func acceptsAReviewThatOnlyQuotesTheFacts() throws {
        let facts = try sampleFacts()
        let draft = WeekReviewDraft(
            headline: "  A steady start  ",
            summary: "You've run 14 km over 2 runs, with a tempo in there. 3 days left to add an easy one.",
            nextFocus: "Keep the next run relaxed."
        )
        let wording = try #require(WeekReview.validated(draft, for: facts, unit: .metric))
        #expect(wording.headline == "A steady start")
        #expect(wording.source == WeekReview.prompt(for: facts, unit: .metric))
    }

    @Test func rejectsAReviewThatDoesItsOwnArithmetic() throws {
        let facts = try sampleFacts()
        let draft = WeekReviewDraft(
            headline: "Good week",
            summary: "You ran 14.0 km, about 7 km a run.",
            nextFocus: "Keep it easy."
        )
        #expect(WeekReview.validated(draft, for: facts, unit: .metric) == nil)
    }

    @Test func rejectsBlankOrRunawayFields() throws {
        let facts = try sampleFacts()
        let blank = WeekReviewDraft(headline: " ", summary: "Fine.", nextFocus: "Rest.")
        let runaway = WeekReviewDraft(
            headline: "Week",
            summary: String(repeating: "Steady. ", count: 60),
            nextFocus: "Rest."
        )
        #expect(WeekReview.validated(blank, for: facts, unit: .metric) == nil)
        #expect(WeekReview.validated(runaway, for: facts, unit: .metric) == nil)
    }

    @Test func numbersCompareByValueButTimesStayAsWritten() {
        #expect(WeekReview.normalizedNumbers(in: "24 km and 24.0 km") == ["24"])
        #expect(WeekReview.normalizedNumbers(in: "1,200 m in 5:12") == ["1200", "5:12"])
    }

    // MARK: Service

    @Test func serviceReturnsTheCheckedReviewFromTheChosenModel() async throws {
        let facts = try sampleFacts()
        let recorder = ReviewRequestRecorder()
        let service = AICoachService(
            onDeviceBackend: ReviewWritingCoach(
                available: true,
                draft: WeekReviewDraft(headline: "Solid so far", summary: "2 runs and 14.0 km.", nextFocus: "Stay easy."),
                recorder: recorder
            )
        )

        let wording = await service.writeWeekReview(for: facts, unit: .metric, provider: .applePrivateCloud)

        #expect(wording?.headline == "Solid so far")
        let requests = await recorder.requests
        #expect(requests.map(\.useServerModel) == [true])
        #expect(requests.first?.instructions == WeekReview.instructions)
        #expect(requests.first?.prompt == WeekReview.prompt(for: facts, unit: .metric))
    }

    @Test func serviceRetriesOnDeviceWhenTheDailyAllowanceIsUsedUp() async throws {
        let facts = try sampleFacts()
        let recorder = ReviewRequestRecorder()
        let service = AICoachService(
            onDeviceBackend: ReviewWritingCoach(
                available: true,
                draft: WeekReviewDraft(headline: "Solid", summary: "14.0 km so far.", nextFocus: "Stay easy."),
                recorder: recorder,
                serverError: .serverQuotaExceeded(resetDate: nil)
            )
        )
        let wording = await service.writeWeekReview(for: facts, unit: .metric, provider: .applePrivateCloud)
        let requests = await recorder.requests
        #expect(requests.map(\.useServerModel) == [true, false])
        #expect(wording != nil)
    }

    @Test func serviceGivesNothingWhenTheModelCannotHelp() async throws {
        let facts = try sampleFacts()
        let invented = WeekReviewDraft(headline: "Big week", summary: "You ran 40 km.", nextFocus: "Rest.")
        let cases: [AICoachService] = [
            AICoachService(onDeviceBackend: nil),
            AICoachService(onDeviceBackend: ReviewWritingCoach(available: false, draft: invented, recorder: .init())),
            AICoachService(onDeviceBackend: ReviewWritingCoach(available: true, draft: nil, recorder: .init())),
            AICoachService(onDeviceBackend: ReviewWritingCoach(available: true, draft: invented, recorder: .init())),
        ]
        for service in cases {
            let wording = await service.writeWeekReview(for: facts, unit: .metric, provider: .applePrivateCloud)
            #expect(wording == nil)
        }
    }

    @Test func storeRoundTripsTheLastWording() throws {
        let defaults = try #require(UserDefaults(suiteName: "WeekReviewTests"))
        defaults.removePersistentDomain(forName: "WeekReviewTests")
        let wording = WeekReviewWording(headline: "H", summary: "S", nextFocus: "F", source: "facts")
        #expect(WeekReviewStore.load(from: defaults) == nil)
        WeekReviewStore.save(wording, to: defaults)
        #expect(WeekReviewStore.load(from: defaults) == wording)
    }
}

// MARK: - Fake backend

private actor ReviewRequestRecorder {
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

/// Writes a canned review, or throws when `draft` is nil, and records what it was asked.
/// `serverError`, when set, is what a request for the server model throws instead.
private struct ReviewWritingCoach: OnDeviceCoachGenerating {
    let available: Bool
    let draft: WeekReviewDraft?
    let recorder: ReviewRequestRecorder
    var serverError: OnDeviceCoachError?

    func isAvailable() async -> Bool { available }
    func unavailableReason() async -> String? { available ? nil : "unavailable" }

    func generateWeekReview(
        instructions: String,
        prompt: String,
        useServerModel: Bool
    ) async throws -> WeekReviewDraft {
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
