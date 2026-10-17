import Foundation
import Testing
@testable import Stride

/// Covers `CoachLookup` — what the coach's read-only tools answer with — and that
/// `AICoachService` hands the lookup and the tools note to the backend only when asked.
struct CoachLookupTests {

    // MARK: Fixtures

    /// Thursday 15 October 2026, midday.
    private let now: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 15; components.hour = 12
        return Calendar.current.date(from: components)!
    }()

    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    private func run(_ days: Int, km: Double, type: WorkoutType = .easy, heartRate: Double? = nil,
                     feel: RunFeel? = nil) -> CoachLookup.Run {
        CoachLookup.Run(
            date: daysAgo(days),
            type: type,
            distanceMeters: km * 1_000,
            durationSeconds: km * 300,
            averageHeartRate: heartRate,
            elevationGainMeters: nil,
            feel: feel
        )
    }

    private var lookup: CoachLookup {
        CoachLookup(
            runs: [
                run(30, km: 12, type: .longRun),
                run(1, km: 8, type: .tempo, heartRate: 161.6, feel: .hard),
                run(3, km: 6),
                run(5, km: 7),
                run(200, km: 10),
            ],
            sessions: [
                CoachLookup.Session(date: daysAgo(2), type: .easy, targetDistanceMeters: 6_000, isCompleted: false),
                CoachLookup.Session(date: daysAgo(1), type: .tempo, targetDistanceMeters: 8_000, isCompleted: true),
                CoachLookup.Session(date: daysAgo(-2), type: .longRun, targetDistanceMeters: 16_000, isCompleted: false),
                CoachLookup.Session(date: daysAgo(-40), type: .race, targetDistanceMeters: 42_195, isCompleted: false),
            ],
            unit: .metric,
            now: now
        )
    }

    // MARK: findRuns

    @Test func findsTheNewestRunsOfOneKind() {
        let answer = lookup.findRuns(type: .easy, withinDays: 14, limit: 5)
        let lines = answer.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first?.contains("Easy, 6.0 km in 30:00, 5:00 min/km") == true)
    }

    @Test func aRunLineCarriesHeartRateAndFeel() {
        let answer = lookup.findRuns(type: .tempo, withinDays: 7, limit: 1)
        #expect(answer.contains("Tempo, 8.0 km in 40:00"))
        #expect(answer.contains("avg HR 162"))
        #expect(answer.contains("felt hard"))
    }

    @Test func findRunsClampsTheWindowAndTheLimit() {
        let everything = lookup.findRuns(type: nil, withinDays: 5_000, limit: 50)
        // The 200-day-old run is past the half-year window.
        #expect(everything.split(separator: "\n").count == 4)
        #expect(lookup.findRuns(type: nil, withinDays: 60, limit: 0).split(separator: "\n").count == 1)
    }

    @Test func saysSoWhenNothingMatches() {
        #expect(lookup.findRuns(type: .interval, withinDays: 30, limit: 5) == "No interval runs in the last 30 days.")
    }

    // MARK: weeklyTotals

    @Test func totalsEachWeekNewestFirst() {
        let lines = lookup.weeklyTotals(weeks: 2).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        // Monday to Thursday midday: the tempo (1 day ago) and the easy 6 km (3 days ago).
        #expect(lines[0] == "This week so far: 14.0 km over 2 runs")
        #expect(lines[1].hasPrefix("Week of "))
        #expect(lines[1].hasSuffix("7.0 km over 1 run"))
        #expect(lookup.weeklyTotals(weeks: 99).split(separator: "\n").count == CoachLookup.maximumWeeks)
    }

    // MARK: planSessions

    @Test func listsPlannedRunsAroundTodayWithTheirState() {
        let lines = lookup.planSessions(daysBack: 7, daysAhead: 7).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("Easy, 6.0 km, missed"))
        #expect(lines[1].hasSuffix("Tempo, 8.0 km, done"))
        #expect(lines[2].hasSuffix("Long Run, 16.0 km, to come"))
    }

    @Test func planSessionsSaysSoWhenTheWindowIsEmpty() {
        let empty = CoachLookup(runs: [], sessions: [], unit: .metric, now: now)
        #expect(empty.planSessions(daysBack: 7, daysAhead: 7) == "No planned runs in that window.")
    }

    @Test func answersInTheRunnersUnit() {
        let imperial = CoachLookup(runs: [run(1, km: 8, type: .tempo)], sessions: [], unit: .imperial, now: now)
        #expect(imperial.findRuns(type: nil, withinDays: 7, limit: 1).contains("5.0 mi"))
    }

    // MARK: rankRuns

    @Test func ranksTheFastestRunsFirst() {
        let lines = lookup.rankRuns(type: nil, withinDays: 60, by: .fastest, limit: 2).split(separator: "\n")
        #expect(lines.count == 2)
        let tempo = CoachLookup.Run(
            date: daysAgo(4), type: .tempo, distanceMeters: 8_000, durationSeconds: 2_160,
            averageHeartRate: nil, elevationGainMeters: nil, feel: nil
        )
        let quick = CoachLookup(runs: [run(2, km: 6), tempo], sessions: [], unit: .metric, now: now)
        let first = quick.rankRuns(type: nil, withinDays: 30, by: .fastest, limit: 1)
        #expect(first.contains("Tempo, 8.0 km in 36:00, 4:30 min/km"))
    }

    @Test func ranksTheLongestAndSkipsRunsWithoutHeartRate() {
        let longest = lookup.rankRuns(type: nil, withinDays: 60, by: .longest, limit: 1)
        #expect(longest.contains("Long Run, 12.0 km"))
        let byHeartRate = lookup.rankRuns(type: nil, withinDays: 60, by: .highestHeartRate, limit: 5)
        #expect(byHeartRate.split(separator: "\n").count == 1)
        #expect(lookup.rankRuns(type: .easy, withinDays: 60, by: .highestHeartRate, limit: 5)
            == "No easy runs with heart rate in the last 60 days.")
    }

    @Test func fastestIgnoresTinyRuns() {
        let tiny = CoachLookup(runs: [run(1, km: 0.4)], sessions: [], unit: .metric, now: now)
        #expect(tiny.rankRuns(type: nil, withinDays: 7, by: .fastest, limit: 3) == "No runs in the last 7 days.")
    }

    // MARK: compareRuns

    @Test func comparesRecentDaysWithTheDaysBefore() {
        let lines = lookup.compareRuns(type: nil, days: 14).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        // 1, 3 and 5 days ago in the recent fortnight; nothing 14 to 28 days ago.
        #expect(lines[0] == "Last 14 days: 3 runs, 21.0 km, 5:00 min/km average, avg HR 162, 1 felt hard")
        #expect(lines[1] == "The 14 days before: no runs")
    }

    @Test func compareRunsClampsTheWindowAndSaysWhenEmpty() {
        #expect(lookup.compareRuns(type: nil, days: 1).hasPrefix("Last 7 days: "))
        #expect(lookup.compareRuns(type: nil, days: 500).hasPrefix("Last 90 days: "))
        #expect(lookup.compareRuns(type: .interval, days: 30) == "No interval runs in the last 60 days.")
    }

    // MARK: racePredictions

    @Test func predictsRaceTimesFromTheFitnessNumber() {
        let fit = CoachLookup(runs: [], sessions: [], unit: .metric, now: now, fitnessVDOT: 50)
        let lines = fit.racePredictions(for: nil).split(separator: "\n").map(String.init)
        #expect(lines.count == 5)
        let fiveK = PaceCalculatorService.predictedTime(vdot: 50, distanceMeters: 5_000)
        #expect(lines[1].hasPrefix("5K: \(fiveK.durationString), "))
        #expect(lines[4].hasPrefix("Marathon: "))
        #expect(fit.racePredictions(for: 10_000).split(separator: "\n").count == 2)
    }

    @Test func saysSoWhenThereIsNoFitnessNumber() {
        #expect(lookup.racePredictions(for: nil) == "Not enough recent hard runs to predict race times.")
    }

    // MARK: Instructions

    @Test func toolsNoteIsAddedOnlyWithALookup() {
        #expect(CoachLookup.instructions("Base.", withToolsFor: nil) == "Base.")
        let withTools = CoachLookup.instructions("Base.", withToolsFor: lookup, today: now)
        #expect(withTools.hasPrefix("Base.\n\n" + CoachLookup.instructionsNote))
        // Tool names live in the tools' own descriptions, which the framework already
        // puts in the prompt; the note does not repeat them.
        #expect(!withTools.contains("findRuns"))
    }

    @Test func toolsNoteSaysWhichDayTheToolsCountFrom() {
        let chat = CoachLookup.instructions("Base.", withToolsFor: lookup, today: now)
        #expect(chat.hasSuffix("Today is Thu 15 Oct 2026. The tools count days back from today."))

        let later = now.addingTimeInterval(3 * 86_400)
        let runRead = CoachLookup.instructions("Base.", withToolsFor: lookup, today: later)
        #expect(runRead.hasSuffix(
            "This run was on Thu 15 Oct 2026. The tools count days back from that day and leave this run out."
        ))
    }

    // MARK: Call budget

    @Test func theBudgetAnswersUntilItIsSpent() {
        let budget = CoachToolBudget(calls: 2)
        #expect(budget.spend { "first" } == "first")
        #expect(budget.spend { "second" } == "second")
        #expect(budget.spend { "third" } == CoachToolBudget.spentAnswer)
        #expect(!CoachToolBudget(calls: 0).take())
    }

    // MARK: Service

    @Test func chatPassesTheLookupAndTheToolsNote() async {
        let recorder = LookupRecorder()
        let service = AICoachService(onDeviceBackend: LookupRecordingCoach(recorder: recorder))

        _ = try? await service.chatWithProvider(
            provider: .applePrivateCloud, context: "ctx", messages: [], lookup: lookup
        )
        _ = try? await service.chatWithProvider(provider: .applePrivateCloud, context: "ctx", messages: [])

        let requests = await recorder.requests
        #expect(requests.map(\.hadLookup) == [true, false])
        #expect(requests.first?.instructions.contains(CoachLookup.instructionsNote) == true)
        #expect(requests.last?.instructions == AICoachService.chatInstructions)
    }

    @Test func aChatThatFailsWithToolsIsAskedAgainWithout() async throws {
        let recorder = LookupRecorder()
        let service = AICoachService(
            onDeviceBackend: LookupRecordingCoach(recorder: recorder, failsWithTools: true)
        )

        let reply = try await service.chatWithProvider(
            provider: .applePrivateCloud, context: "ctx", messages: [], lookup: lookup
        )

        let requests = await recorder.requests
        #expect(reply == "ok")
        #expect(requests.map(\.hadLookup) == [true, false])
        #expect(requests.last?.instructions == AICoachService.chatInstructions)
    }
}

// MARK: - Fake backend

private actor LookupRecorder {
    struct Request: Sendable {
        let instructions: String
        let hadLookup: Bool
    }

    private(set) var requests: [Request] = []

    func record(_ request: Request) {
        requests.append(request)
    }
}

/// Records whether each chat request came with a lookup. Implements the tool-taking
/// variant directly, as the real backend does.
private struct LookupRecordingCoach: OnDeviceCoachGenerating {
    let recorder: LookupRecorder
    var failsWithTools = false

    func isAvailable() async -> Bool { true }
    func unavailableReason() async -> String? { nil }

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        lookup: CoachLookup?,
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        await recorder.record(.init(instructions: instructions, hadLookup: lookup != nil))
        if failsWithTools, lookup != nil { throw OnDeviceCoachError.malformedResponse }
        return "ok"
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
