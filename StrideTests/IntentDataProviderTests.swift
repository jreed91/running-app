import Foundation
import SwiftData
import Testing
@testable import Stride

// MARK: - Intent data provider tests

@MainActor
struct IntentDataProviderTests {

    /// M34: the Weekly Summary intent must bucket runs by the app-wide
    /// Monday-based week (`Date.startOfWeek`), not `Calendar.current`'s default
    /// week start (Sunday in the US). Otherwise Siri and the dashboard disagree
    /// by a whole run on Sundays/Mondays.
    @Test("Weekly summary sums only the current Monday-based week")
    func weeklySummaryUsesMondayWeek() async throws {
        let schema = StrideSchema.make()
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let startOfWeek = Date().startOfWeek

        // In the current week (Tuesday) — counted.
        context.insert(RunWorkout(date: startOfWeek.adding(days: 1), distanceMeters: 5_000, durationSeconds: 1_500))
        // The day before this week started (previous Sunday) — a different
        // Monday-week, so excluded. Under the old Sunday-week logic this would
        // have leaked into the total.
        context.insert(RunWorkout(date: startOfWeek.adding(days: -1), distanceMeters: 3_000, durationSeconds: 900))
        // Next week — excluded.
        context.insert(RunWorkout(date: startOfWeek.adding(days: 7), distanceMeters: 7_000, durationSeconds: 2_100))
        try context.save()

        let actor = IntentModelActor(modelContainer: container)
        let summary = try await actor.weeklySummary()

        #expect(abs(summary.totalMeters - 5_000) < 0.01)
    }
}
