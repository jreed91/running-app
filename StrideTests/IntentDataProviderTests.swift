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
        // File-backed, not in-memory. `IntentModelActor` is a `@ModelActor`, so it reads
        // through its own `ModelContext` on its own executor while this test writes
        // through `mainContext`. An in-memory store does not survive that second
        // connection here — it throws "No eligible connection available", which is an
        // ObjC exception and so aborts the whole test host rather than failing a test.
        // A temporary file store is also the truer fixture: `IntentDataProvider`
        // opens the app's on-disk store in production, never an in-memory one.
        let storeURL = Self.makeTemporaryStoreURL()
        defer { Self.removeStoreArtifacts(at: storeURL) }
        // `.none` to match `IntentDataProvider`, and because the test host is the app:
        // omitting it defaults to `.automatic`, which resolves the container out of the
        // host's entitlements and syncs the fixture to iCloud (F1).
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
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
        // File-backed, not in-memory. `IntentModelActor` is a `@ModelActor`, so it reads
        // through its own `ModelContext` on its own executor while this test writes
        // through `mainContext`. An in-memory store does not survive that second
        // connection here — it throws "No eligible connection available", which is an
        // ObjC exception and so aborts the whole test host rather than failing a test.
        // A temporary file store is also the truer fixture: `IntentDataProvider`
        // opens the app's on-disk store in production, never an in-memory one.
        let storeURL = Self.makeTemporaryStoreURL()
        defer { Self.removeStoreArtifacts(at: storeURL) }
        // `.none` to match `IntentDataProvider`, and because the test host is the app:
        // omitting it defaults to `.automatic`, which resolves the container out of the
        // host's entitlements and syncs the fixture to iCloud (F1).
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
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

    /// N13 (dialog half): `todaysRun()` falls back to a gym or cross-training day when
    /// nothing is scheduled to be run, so the spoken answer has to branch on the session
    /// kind instead of calling everything a run.
    @Test("Siri's answer only calls run types runs")
    func dialogWordsEachSessionKind() {
        func text(_ type: WorkoutType) -> String {
            TodaysRunIntent.dialogText(
                for: TodaysRunData(workoutType: type, distanceMeters: nil, notes: nil)
            )
        }

        #expect(text(.tempo) == "You have a Tempo run today.")
        #expect(text(.longRun) == "You have a Long Run today.")
        #expect(text(.race) == "You have a Race today.")
        #expect(text(.strength) == "You have a Strength session today.")
        #expect(!text(.crossTraining).contains("run"))
        #expect(!text(.walk).contains("run"))
        #expect(text(.rest) == "Today is a rest day.")
        #expect(TodaysRunIntent.dialogText(for: nil) == "No run scheduled for today.")
    }

    /// Siri AI preview "find runs" tool: the search fills in a type, a day range in
    /// either order, and a minimum distance; walks never come back as runs (N38).
    @Test("Find runs filters by type, inclusive day range and minimum distance")
    func findRunsFilters() async throws {
        let schema = StrideSchema.make()
        // File-backed for the same reason as the tests above: `IntentModelActor` reads
        // through its own context, which an in-memory store does not survive.
        let storeURL = Self.makeTemporaryStoreURL()
        defer { Self.removeStoreArtifacts(at: storeURL) }
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let today = Date().startOfDay
        // Late on the search's last day: inside an inclusive range.
        let lastDayLong = RunWorkout(
            date: today.addingTimeInterval(22 * 3_600), distanceMeters: 21_000, durationSeconds: 7_200,
            workoutType: .longRun
        )
        let shortLong = RunWorkout(
            date: today.adding(days: -3), distanceMeters: 12_000, durationSeconds: 4_000, workoutType: .longRun
        )
        let tempo = RunWorkout(
            date: today.adding(days: -2), distanceMeters: 22_000, durationSeconds: 6_000, workoutType: .tempo
        )
        let tooOld = RunWorkout(
            date: today.adding(days: -40), distanceMeters: 25_000, durationSeconds: 9_000, workoutType: .longRun
        )
        let walk = RunWorkout(
            date: today.adding(days: -1), distanceMeters: 30_000, durationSeconds: 20_000, workoutType: .walk
        )
        for run in [lastDayLong, shortLong, tempo, tooOld, walk] { context.insert(run) }
        try context.save()

        let actor = IntentModelActor(modelContainer: container)

        // Range given backwards (today, then 30 days ago) still searches those days.
        let longOver20 = try await actor.findRuns(
            workoutType: .longRun, from: today, to: today.adding(days: -30),
            minimumMeters: 20_000, limit: 20, unit: .metric
        )
        #expect(longOver20.map(\.id) == [lastDayLong.id])

        // Any type, newest first, no walk.
        let anyOver20 = try await actor.findRuns(
            workoutType: nil, from: today.adding(days: -30), to: today,
            minimumMeters: 20_000, limit: 20, unit: .metric
        )
        #expect(anyOver20.map(\.id) == [lastDayLong.id, tempo.id])

        let capped = try await actor.findRuns(
            workoutType: nil, from: today.adding(days: -60), to: today,
            minimumMeters: 0, limit: 2, unit: .metric
        )
        #expect(capped.count == 2)
    }

    @Test("Find runs answer counts runs and totals the distance")
    func findRunsDialog() {
        #expect(RunSearchDialog.text(count: 0, totalMeters: 0, unit: .metric) == "No runs match that.")
        #expect(RunSearchDialog.text(count: 1, totalMeters: 21_000, unit: .metric) == "Found 1 run, 21.0 km.")
        #expect(
            RunSearchDialog.text(count: 2, totalMeters: 43_000, unit: .metric)
                == "Found 2 runs, 43.0 km in total."
        )
    }

    // MARK: - Fixtures

    private static func makeTemporaryStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("store")
    }

    private static func removeStoreArtifacts(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
