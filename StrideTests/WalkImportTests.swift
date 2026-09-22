import Foundation
import SwiftData
import Testing
@testable import Stride

// MARK: - Walk import (N38)
//
// Walking workouts are imported from Apple Health into the same `RunWorkout` table as
// runs, carrying `WorkoutType.walk`. That choice buys the history row, the map, the
// splits and the heart-rate charts for free, and it costs exactly one invariant, which
// is what this file exists to hold:
//
//   **A walk is history, never training.**
//
// Every aggregate that means *running* — weekly volume, average pace, VDOT, personal
// records, the streak, the coach's read, the widgets' week, the plan's pace refresh —
// has to drop walks, or a stroll lands in the same average as a tempo run and quietly
// moves a number the runner trusts.

@MainActor
struct WalkImportTests {

    // MARK: Fixtures

    private func run(
        daysAgo: Double,
        km: Double = 10,
        paceSecondsPerKm: Double = 300,
        type: WorkoutType = .easy,
        now: Date = Date()
    ) -> RunWorkout {
        RunWorkout(
            date: now.addingTimeInterval(-daysAgo * 86_400),
            distanceMeters: km * 1_000,
            durationSeconds: km * paceSecondsPerKm,
            workoutType: type
        )
    }

    private func walk(daysAgo: Double, km: Double = 4, now: Date = Date()) -> RunWorkout {
        run(daysAgo: daysAgo, km: km, paceSecondsPerKm: 750, type: .walk, now: now)
    }

    // MARK: - The type itself

    @Test("A walk is neither a run type nor running")
    func walkIsNotRunning() {
        #expect(!WorkoutType.walk.isRunType)
        #expect(!WorkoutType.walk.countsAsRunning)
        #expect(!WorkoutType.walk.isQualitySession)
        #expect(WorkoutType.walk.sessionKind == .walk)
        // Everything else still counts, so the new case cannot have widened the rule.
        // Cross-training is the one other exception, and `CrossTrainingImportTests` owns it.
        for type in WorkoutType.allCases where type != .walk && type != .crossTraining {
            #expect(type.countsAsRunning)
        }
    }

    @Test("runsOnly and walksOnly partition a mixed history")
    func collectionHelpersPartition() {
        let history = [run(daysAgo: 1), walk(daysAgo: 2), run(daysAgo: 3, type: .tempo)]
        #expect(history.runsOnly.count == 2)
        #expect(history.walksOnly.count == 1)
        #expect(history.runsOnly.allSatisfy { !$0.isWalk })
    }

    // MARK: - Import rules

    @Test("An imported walk is a walk whatever pace it was taken at")
    func walkIsNeverClassifiedByPace() {
        // Fast enough to clear a 30-minute-5K runner's marathon pace, which for a *run*
        // is what makes it a tempo. A brisk walk must not become a quality session.
        let paces = PaceCalculatorService.trainingPaces(from5KTimeSeconds: 1_800)
        let type = HealthKitRepository.ImportKind.walk.workoutType(
            distanceMeters: 5_000,
            durationSeconds: 5_000 / 1_000 * 300,
            paces: paces
        )
        #expect(type == .walk)

        // The run kind still infers, so the shared path did not flatten that.
        let runType = HealthKitRepository.ImportKind.run.workoutType(
            distanceMeters: 5_000,
            durationSeconds: 5_000 / 1_000 * 300,
            paces: paces
        )
        #expect(runType == .tempo)
    }

    @Test("The walk floor is higher than the run floor")
    func walkFloorRejectsErrands() {
        let walk = HealthKitRepository.ImportKind.walk
        // A four-minute walk to the shop: real movement, not a session.
        #expect(!walk.isImportable(distanceMeters: 300, durationSeconds: 240))
        #expect(!walk.isImportable(distanceMeters: 900, durationSeconds: 240))
        #expect(!walk.isImportable(distanceMeters: 300, durationSeconds: 1_800))
        // Half an hour and two kilometres: a walk somebody meant to record.
        #expect(walk.isImportable(distanceMeters: 2_000, durationSeconds: 1_800))

        // The run floor is untouched — a 150 m / 45 s run still imports (M11).
        #expect(HealthKitRepository.ImportKind.run.isImportable(distanceMeters: 150, durationSeconds: 45))
    }

    // MARK: - Training aggregates

    @Test("A walk does not extend a running streak")
    func walkDoesNotExtendStreak() {
        let now = Date()
        // Ran today and yesterday, walked the day before: a two-day streak, not three.
        let history = [run(daysAgo: 0, now: now), run(daysAgo: 1, now: now), walk(daysAgo: 2, now: now)]
        let summary = StreakGoalService.streak(for: history, now: now)
        #expect(summary.current == 2)
        #expect(summary.longest == 2)
    }

    @Test("A walk does not count toward the weekly distance goal")
    func walkDoesNotCountTowardWeeklyGoal() {
        let now = Date()
        let weekStart = StreakGoalService.startOfWeek(for: now, calendar: .current)
        // Anchored inside the week regardless of which weekday the suite runs on.
        let inWeek = weekStart.addingTimeInterval(3_600)
        let ran = RunWorkout(date: inWeek, distanceMeters: 10_000, durationSeconds: 3_000)
        let walked = RunWorkout(
            date: inWeek, distanceMeters: 5_000, durationSeconds: 3_600, workoutType: .walk
        )
        let progress = StreakGoalService.weeklyProgress(
            for: [ran, walked], goalMeters: 20_000, now: now
        )
        #expect(progress.completedMeters == 10_000)
    }

    @Test("The Progress tab's period totals exclude walks")
    func periodStatsExcludeWalks() {
        let now = Date()
        let history = [run(daysAgo: 1, km: 10, now: now), walk(daysAgo: 2, km: 5, now: now)]
        let inRange = ProgressPeriodStats.runs(in: history, withinDays: 30, now: now)
        #expect(inRange.count == 1)
        #expect(ProgressPeriodStats.summary(for: inRange).totalDistanceMeters == 10_000)
    }

    @Test("Average pace is not dragged by a walk")
    func averagePaceExcludesWalks() {
        // 10 km at 5:00/km, plus a 4 km walk at 12:30/km. Unfiltered, the weighted
        // average lands past 7:00/km — a runner losing two minutes a kilometre overnight.
        let history = [run(daysAgo: 1, km: 10, paceSecondsPerKm: 300), walk(daysAgo: 2, km: 4)]
        let pace = ProgressStatsService.distanceWeightedAveragePaceSecondsPerKm(for: history)
        #expect(abs(pace - 300) < 0.5)
    }

    @Test("A walk cannot be a personal record")
    func walkIsNeverAPersonalRecord() {
        // Long enough to qualify on distance, and the only entry in the set.
        let history = [walk(daysAgo: 1, km: 6)]
        let record = ProgressStatsService.personalRecordRun(
            in: history,
            targetMeters: 5_000,
            eligibleTypes: [.easy, .tempo, .interval, .longRun, .race]
        )
        #expect(record == nil)
    }

    @Test("A walk does not contribute a fitness sample")
    func walkProducesNoVDOTSample() {
        #expect(ProgressStatsService.estimatedVDOT(for: walk(daysAgo: 1, km: 5)) == nil)
    }

    @Test("Walking through a layoff does not hide it from the coach")
    func walkDoesNotResetTheLayoffClock() {
        let now = Date()
        // Last ran a fortnight ago; walked yesterday.
        let history = [run(daysAgo: 14, now: now), walk(daysAgo: 1, now: now)]
        let situation = CoachSituation.resolve(
            nextSession: nil,
            recentRuns: history,
            profile: nil,
            dayState: .noPlan,
            now: now
        )
        // The case, not the exact day count: the count is calendar arithmetic that a DST
        // boundary can move by one, and what this test is about is that the walk did not
        // answer the question.
        if case .returningFromLayoff = situation {} else {
            Issue.record("Expected a layoff situation, got \(situation)")
        }
    }

    @Test("The widget's week counts runs, not walks")
    func widgetWeeklyExcludesWalks() {
        let now = Date()
        let weekStart = StreakGoalService.startOfWeek(for: now, calendar: .current)
        let inWeek = weekStart.addingTimeInterval(3_600)
        let ran = RunWorkout(date: inWeek, distanceMeters: 8_000, durationSeconds: 2_400)
        let walked = RunWorkout(
            date: inWeek, distanceMeters: 5_000, durationSeconds: 3_600, workoutType: .walk
        )
        let weekly = WidgetSnapshotBuilder.weekly(
            runs: [ran, walked], goalMeters: 20_000, unit: .metric, now: now
        )
        #expect(weekly.runCount == 1)
    }

    // MARK: - Store-level fetches

    @Test("runsOnlyDescriptor filters in the fetch, so a limit still counts runs")
    func descriptorFiltersInTheFetch() throws {
        let context = TestStore.makeContext()
        let now = Date()
        // Newest first: two walks, then a run. A post-fetch filter on `fetchLimit = 1`
        // would return nothing at all here.
        context.insert(walk(daysAgo: 0, now: now))
        context.insert(walk(daysAgo: 1, now: now))
        context.insert(run(daysAgo: 2, now: now))
        try context.save()

        let newest = try context.fetch(RunWorkout.runsOnlyDescriptor(fetchLimit: 1))
        #expect(newest.count == 1)
        #expect(newest.first?.isWalk == false)

        let all = try context.fetch(RunWorkout.runsOnlyDescriptor())
        #expect(all.count == 1)
    }

    @Test("The workout repository returns runs and the store still holds the walks")
    func repositoryExcludesWalks() throws {
        let context = TestStore.makeContext()
        let now = Date()
        context.insert(run(daysAgo: 1, now: now))
        context.insert(walk(daysAgo: 2, now: now))
        try context.save()

        let repository = WorkoutRepository(context: context)
        let all = try repository.fetchAll()
        let recent = try repository.fetchRecent(limit: 5)
        let ranged = try repository.fetch(from: now.addingTimeInterval(-86_400 * 7), to: now)
        #expect(all.count == 1)
        #expect(recent.count == 1)
        #expect(ranged.count == 1)
        // The walk is not gone — History reads the store directly and must still see it.
        let everything = try context.fetch(FetchDescriptor<RunWorkout>())
        #expect(everything.count == 2)
    }
}

// MARK: - Walk sync

@MainActor
struct WalkSyncTests {

    /// The toggle is read through `UserDefaults.standard` (a background sync can run
    /// before `AppSettings` exists), so a test that wants a value has to write one there
    /// and put the key back afterwards.
    private func withWalkImport<T>(_ enabled: Bool, _ body: () async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppSettings.walkImportKey)
        defaults.set(enabled, forKey: AppSettings.walkImportKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppSettings.walkImportKey)
            } else {
                defaults.removeObject(forKey: AppSettings.walkImportKey)
            }
        }
        return try await body()
    }

    private func makeService(mock: MockHealthKitRepository) -> (WorkoutSyncService, ModelContext) {
        let context = TestStore.makeContext()
        let service = WorkoutSyncService(
            healthKitRepository: mock,
            notificationService: NotificationService.shared,
            weatherService: WeatherService(),
            context: context
        )
        return (service, context)
    }

    private func makeWalk() -> RunWorkout {
        let walk = RunWorkout(
            date: Date(),
            distanceMeters: 3_000,
            durationSeconds: 2_400,
            workoutType: .walk
        )
        walk.healthKitWorkoutID = UUID().uuidString
        return walk
    }

    @Test("A synced walk lands in the store as a walk")
    func walkIsImported() async throws {
        try await withWalkImport(true) {
            let mock = MockHealthKitRepository()
            mock.walkFetchResults = [[makeWalk()]]
            let (service, context) = makeService(mock: mock)

            await service.syncNow(source: "test")

            let stored = try context.fetch(FetchDescriptor<RunWorkout>())
            #expect(stored.count == 1)
            #expect(stored.first?.workoutType == .walk)
        }
    }

    @Test("Turning walk import off stops the fetch entirely")
    func walkImportRespectsTheToggle() async throws {
        try await withWalkImport(false) {
            let mock = MockHealthKitRepository()
            mock.walkFetchResults = [[makeWalk()]]
            let (service, context) = makeService(mock: mock)

            await service.syncNow(source: "test")

            let stored = try context.fetch(FetchDescriptor<RunWorkout>())
            #expect(mock.walkFetchCalls == 0)
            #expect(stored.isEmpty)
        }
    }

    /// The failure this guards: a runner misses Tuesday's easy run, walks the dog on
    /// Tuesday evening, and the plan marks the run done.
    @Test("An imported walk never completes a scheduled run")
    func walkDoesNotCompleteAPlannedRun() async throws {
        try await withWalkImport(true) {
            let mock = MockHealthKitRepository()
            mock.walkFetchResults = [[makeWalk()]]
            let (service, context) = makeService(mock: mock)

            let plan = TrainingPlan(
                targetRace: .fiveK,
                goalTimeSeconds: 1_500,
                startDate: Date(),
                endDate: Date().addingTimeInterval(86_400 * 30)
            )
            plan.isActive = true
            let week = TrainingWeek(weekNumber: 1, startDate: Date(), phase: .base, targetDistanceKm: 20)
            let scheduled = ScheduledWorkout(
                scheduledDate: Date(),
                workoutType: .easy,
                targetDistanceMeters: 5_000
            )
            week.workouts = [scheduled]
            plan.weeks = [week]
            context.insert(plan)
            try context.save()

            await service.syncNow(source: "test")

            #expect(scheduled.isCompleted == false)
            #expect(scheduled.completedWorkout == nil)
        }
    }
}
