import Foundation
import HealthKit
import SwiftData
import Testing
@testable import Stride

// MARK: - Cross-training import (B8)
//
// Rides, swims, rows and elliptical sessions recorded in Apple Health are imported into
// the `RunWorkout` table carrying `WorkoutType.crossTraining`, the way walks are (N38).
// Two invariants hold the feature together, and this file pins both:
//
//   **A cross-training session is never running history.** A 30 km ride in the weekly
//   distance or an hour on the bike as a VDOT sample is a wrong number, not a bonus.
//
//   **It completes a cross-training day, and only that.** It must not complete a run
//   day, and a run must not complete it.

@MainActor
struct CrossTrainingImportTests {

    // MARK: Fixtures

    private func run(daysAgo: Double, km: Double = 10, now: Date = Date()) -> RunWorkout {
        RunWorkout(
            date: now.addingTimeInterval(-daysAgo * 86_400),
            distanceMeters: km * 1_000,
            durationSeconds: km * 300
        )
    }

    private func ride(daysAgo: Double, km: Double = 30, now: Date = Date()) -> RunWorkout {
        RunWorkout(
            date: now.addingTimeInterval(-daysAgo * 86_400),
            distanceMeters: km * 1_000,
            durationSeconds: 3_600,
            workoutType: .crossTraining
        )
    }

    // MARK: - The type

    @Test("Cross-training is neither a run type nor running")
    func crossTrainingIsNotRunning() {
        #expect(!WorkoutType.crossTraining.isRunType)
        #expect(!WorkoutType.crossTraining.countsAsRunning)
        #expect(WorkoutType.crossTraining.sessionKind == .crossTraining)
        #expect(ride(daysAgo: 1).isCrossTraining)
        #expect(!ride(daysAgo: 1).countsAsRunning)
    }

    @Test("runsOnly drops cross-training sessions")
    func runsOnlyDropsRides() {
        let history = [run(daysAgo: 1), ride(daysAgo: 2), run(daysAgo: 3)]
        #expect(history.runsOnly.count == 2)
        #expect(history.runsOnly.allSatisfy { !$0.isCrossTraining })
    }

    // MARK: - Import rules

    @Test("An imported session is cross-training whatever its pace")
    func sessionIsNeverClassifiedByPace() {
        // A ride at 2:00/km would be a race-pace *run* for anybody.
        let paces = PaceCalculatorService.trainingPaces(from5KTimeSeconds: 1_200)
        let type = HealthKitRepository.ImportKind.crossTraining.workoutType(
            distanceMeters: 30_000,
            durationSeconds: 3_600,
            paces: paces
        )
        #expect(type == .crossTraining)
    }

    @Test("The cross-training floor is time only")
    func floorIsTimeOnly() {
        let kind = HealthKitRepository.ImportKind.crossTraining
        // An elliptical session records no distance and is still a session.
        #expect(kind.isImportable(distanceMeters: 0, durationSeconds: 30 * 60))
        // The ride to the station is not.
        #expect(!kind.isImportable(distanceMeters: 3_000, durationSeconds: 8 * 60))
        #expect(kind.isImportable(distanceMeters: 0, durationSeconds: 10 * 60))
    }

    @Test("Only runs and walks read the walking/running samples")
    func footSamplesAreForRunsAndWalks() {
        #expect(HealthKitRepository.ImportKind.run.readsFootSamples)
        #expect(HealthKitRepository.ImportKind.walk.readsFootSamples)
        #expect(!HealthKitRepository.ImportKind.crossTraining.readsFootSamples)
    }

    @Test("The imported activities are cardio, not runs, walks, hikes or the gym")
    func activityTypes() {
        let types = Set(CrossTrainingImportPolicy.activityTypes.map(\.rawValue))
        for included: HKWorkoutActivityType in [.cycling, .swimming, .rowing, .elliptical] {
            #expect(types.contains(included.rawValue))
        }
        for excluded: HKWorkoutActivityType in [
            .running, .walking, .hiking,
            .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining
        ] {
            #expect(!types.contains(excluded.rawValue))
        }
    }

    @Test("A session is never offered a split backfill")
    func sessionGetsNoSplitBackfill() {
        let session = ride(daysAgo: 1)
        session.healthKitWorkoutID = UUID().uuidString
        // Long enough, from HealthKit, no splits: a run like this would be backfilled.
        #expect(!SplitBackfill.needsSplits(session, splitLengthMeters: 1_000))
        #expect(!SplitBackfill.needsDistanceSeries(session))
    }

    // MARK: - Training aggregates

    @Test("A ride does not count toward the weekly running goal")
    func rideDoesNotCountTowardWeeklyGoal() {
        let now = Date()
        let weekStart = StreakGoalService.startOfWeek(for: now, calendar: .current)
        let inWeek = weekStart.addingTimeInterval(3_600)
        let ran = RunWorkout(date: inWeek, distanceMeters: 10_000, durationSeconds: 3_000)
        let rode = RunWorkout(
            date: inWeek, distanceMeters: 40_000, durationSeconds: 5_400, workoutType: .crossTraining
        )
        let progress = StreakGoalService.weeklyProgress(for: [ran, rode], goalMeters: 20_000, now: now)
        #expect(progress.completedMeters == 10_000)
    }

    @Test("runsOnlyDescriptor and the workout repository leave rides in the store")
    func storeFetchesExcludeRides() throws {
        let context = TestStore.makeContext()
        let now = Date()
        context.insert(ride(daysAgo: 0, now: now))
        context.insert(run(daysAgo: 1, now: now))
        try context.save()

        let newest = try context.fetch(RunWorkout.runsOnlyDescriptor(fetchLimit: 1))
        #expect(newest.count == 1)
        #expect(newest.first?.isCrossTraining == false)

        let repository = WorkoutRepository(context: context)
        #expect(try repository.fetchAll().count == 1)
        #expect(try repository.fetchRecent(limit: 5).count == 1)
        #expect(try repository.fetch(from: now.addingTimeInterval(-86_400 * 7), to: now).count == 1)
        // History reads the store directly and still sees both.
        #expect(try context.fetch(FetchDescriptor<RunWorkout>()).count == 2)
    }

    @Test("A ride that completed a plan day is time in the plan summary, not distance")
    func planTotalsReadTheLinkAsRunningOnly() throws {
        let context = TestStore.makeContext()
        let now = Date()
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: now,
            endDate: now.addingTimeInterval(86_400 * 30)
        )
        context.insert(plan)
        let week = TrainingWeek(weekNumber: 1, startDate: now, phase: .base, targetDistanceKm: 20)
        context.insert(week)
        week.plan = plan

        let easyDay = ScheduledWorkout(scheduledDate: now, workoutType: .easy, targetDistanceMeters: 8_000)
        let crossDay = ScheduledWorkout(scheduledDate: now, workoutType: .crossTraining)
        for day in [easyDay, crossDay] {
            context.insert(day)
            day.week = week
        }

        let ran = run(daysAgo: 0, km: 8, now: now)
        let rode = ride(daysAgo: 0, km: 30, now: now)
        context.insert(ran)
        context.insert(rode)
        easyDay.completedWorkout = ran
        easyDay.isCompleted = true
        crossDay.completedWorkout = rode
        crossDay.isCompleted = true
        try context.save()

        #expect(abs(week.completedDistanceKm - 8) < 0.001)

        let summary = PlanSummaryService.summary(for: plan, now: now)
        #expect(summary.completedDistanceMeters == 8_000)
        #expect(summary.completedRunCount == 1)
        #expect(summary.completedCount == 2)
        #expect(summary.totalDurationSeconds == ran.durationSeconds + rode.durationSeconds)
    }
}

// MARK: - Cross-training sync

@MainActor
struct CrossTrainingSyncTests {

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

    private func makeSession(date: Date = Date()) -> RunWorkout {
        let session = RunWorkout(
            date: date,
            distanceMeters: 25_000,
            durationSeconds: 3_000,
            workoutType: .crossTraining
        )
        session.healthKitWorkoutID = UUID().uuidString
        return session
    }

    /// An active plan with one scheduled workout of `type` on `date`, inserted.
    @discardableResult
    private func insertPlanDay(
        _ type: WorkoutType,
        on date: Date = Date(),
        in context: ModelContext
    ) throws -> ScheduledWorkout {
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: date,
            endDate: date.addingTimeInterval(86_400 * 30)
        )
        plan.isActive = true
        let week = TrainingWeek(weekNumber: 1, startDate: date, phase: .base, targetDistanceKm: 20)
        let scheduled = ScheduledWorkout(
            scheduledDate: date,
            workoutType: type,
            targetDistanceMeters: type.isRunType ? 5_000 : nil
        )
        week.workouts = [scheduled]
        plan.weeks = [week]
        context.insert(plan)
        try context.save()
        return scheduled
    }

    @Test("A synced session lands in the store as cross-training")
    func sessionIsImported() async throws {
        let mock = MockHealthKitRepository()
        mock.crossTrainingFetchResults = [[makeSession()]]
        let (service, context) = makeService(mock: mock)

        await service.syncNow(source: "test")

        let stored = try context.fetch(FetchDescriptor<RunWorkout>())
        #expect(mock.crossTrainingFetchCalls == 1)
        #expect(stored.count == 1)
        #expect(stored.first?.workoutType == .crossTraining)
    }

    @Test("An imported session completes the plan's cross-training day")
    func sessionCompletesCrossTrainingDay() async throws {
        let mock = MockHealthKitRepository()
        let session = makeSession()
        mock.crossTrainingFetchResults = [[session]]
        let (service, context) = makeService(mock: mock)
        let scheduled = try insertPlanDay(.crossTraining, in: context)

        await service.syncNow(source: "test")

        #expect(scheduled.isCompleted)
        #expect(scheduled.completedWorkout?.id == session.id)
        #expect(scheduled.linkedRunWorkoutID == session.id)
        #expect(session.linkedScheduledWorkoutID == scheduled.id)
    }

    @Test("A session the day after its cross-training day still completes it")
    func sessionCompletesYesterdaysDay() async throws {
        let mock = MockHealthKitRepository()
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        mock.crossTrainingFetchResults = [[makeSession(date: now)]]
        let (service, context) = makeService(mock: mock)
        let scheduled = try insertPlanDay(.crossTraining, on: yesterday, in: context)

        await service.syncNow(source: "test")

        #expect(scheduled.isCompleted)
    }

    /// The failure this guards: a runner skips Tuesday's easy run, rides instead, and the
    /// plan marks the run done.
    @Test("An imported session never completes a scheduled run")
    func sessionDoesNotCompleteARun() async throws {
        let mock = MockHealthKitRepository()
        mock.crossTrainingFetchResults = [[makeSession()]]
        let (service, context) = makeService(mock: mock)
        let scheduled = try insertPlanDay(.easy, in: context)

        await service.syncNow(source: "test")

        #expect(scheduled.isCompleted == false)
        #expect(scheduled.completedWorkout == nil)
    }

    @Test("An imported run never completes a cross-training day")
    func runDoesNotCompleteCrossTrainingDay() async throws {
        let mock = MockHealthKitRepository()
        let run = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 2_400)
        run.healthKitWorkoutID = UUID().uuidString
        mock.runFetchResults = [[run]]
        let (service, context) = makeService(mock: mock)
        let scheduled = try insertPlanDay(.crossTraining, in: context)

        await service.syncNow(source: "test")

        #expect(scheduled.isCompleted == false)
        #expect(run.scheduledWorkout == nil)
    }
}
