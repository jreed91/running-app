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

    /// N13: retired plans keep their future days (they are preserved as history rather
    /// than deleted), so "Today's Run" has to ask the *active* plan or Siri can read out
    /// a workout from a plan the runner already replaced.
    @Test("Today's Run ignores a retired plan's day and reads the active plan's")
    func todaysRunUsesTheActivePlan() async throws {
        let schema = StrideSchema.make()
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let today = Date().startOfDay

        func addPlan(isActive: Bool, workoutType: WorkoutType, distanceMeters: Double, hour: Double) {
            let plan = TrainingPlan(
                targetRace: .fiveK,
                goalTimeSeconds: 1_500,
                startDate: today,
                endDate: today.adding(days: 6)
            )
            plan.isActive = isActive
            context.insert(plan)
            let week = TrainingWeek(weekNumber: 1, startDate: today, phase: .base, targetDistanceKm: 20)
            context.insert(week)
            week.plan = plan
            let workout = ScheduledWorkout(
                scheduledDate: today.addingTimeInterval(hour * 3_600),
                workoutType: workoutType,
                targetDistanceMeters: distanceMeters
            )
            context.insert(workout)
            workout.week = week
        }

        // The retired plan's day is earlier, so it sorts first and an unscoped fetch
        // would return it.
        addPlan(isActive: false, workoutType: .interval, distanceMeters: 8_000, hour: 5)
        addPlan(isActive: true, workoutType: .easy, distanceMeters: 5_000, hour: 6)
        try context.save()

        let actor = IntentModelActor(modelContainer: container)
        let data = try await actor.todaysRun()

        #expect(data?.workoutType == .easy)
        #expect(data?.distanceMeters == 5_000)
    }
}
