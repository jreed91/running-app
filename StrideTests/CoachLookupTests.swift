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

    // MARK: Instructions

    @Test func toolsNoteIsAddedOnlyWithALookup() {
        #expect(CoachLookup.instructions("Base.", withToolsFor: nil) == "Base.")
        let withTools = CoachLookup.instructions("Base.", withToolsFor: lookup)
        #expect(withTools.hasPrefix("Base.\n\n"))
        #expect(withTools.contains("findRuns"))
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
