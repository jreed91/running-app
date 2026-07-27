import Foundation
import SwiftData
import Testing
@testable import Stride

@MainActor
struct MissedWorkoutsRecoveryTests {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
    }

    private func makeContainer() -> AppContainer { TestStore.makeContainer() }

    private func makeProfile(in context: ModelContext) -> UserProfile {
        let profile = UserProfile(
            name: "Test Runner",
            goalRace: .halfMarathon,
            goalFinishTime: 90 * 60,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate,
            currentEstimated5KTimeSeconds: 25 * 60,
            preferredRunDayIndices: [0, 2, 4, 5]
        )
        context.insert(profile)
        return profile
    }

    /// Creates and saves a plan starting at `startDate` with 8 weeks.
    private func makePlan(
        container: AppContainer,
        profile: UserProfile,
        startDate: Date
    ) throws -> TrainingPlan {
        let plan = container.trainingPlanService.generatePlan(
            profile: profile,
            startDate: startDate,
            numberOfWeeks: 8,
            runDayIndices: [0, 2, 4, 5]
        )
        try container.planRepository.save(plan)
        return plan
    }

    private func futureNonRestWorkouts(in plan: TrainingPlan, from today: Date) -> [ScheduledWorkout] {
        let startOfToday = Calendar.current.startOfDay(for: today)
        return (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter {
                !$0.isCompleted
                    && $0.workoutType != .rest
                    && $0.workoutType != .strength
                    && $0.workoutType != .crossTraining
                    && $0.scheduledDate >= startOfToday
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    // MARK: shiftMissedWorkoutsForward

    @Test("shiftMissedWorkoutsForward shifts future non-rest workouts by N days")
    func shiftMovesWorkouts() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()
        let plan = try makePlan(container: container, profile: profile, startDate: today.adding(weeks: -2))

        let before = futureNonRestWorkouts(in: plan, from: today)
        let originalDates = before.map { $0.scheduledDate }
        guard !before.isEmpty else { return }

        try container.planLifecycle.shiftMissedWorkoutsForward(plan: plan, by: 5, context: context)

        for (index, workout) in before.enumerated() {
            let expected = Calendar.current.date(byAdding: .day, value: 5, to: originalDates[index])!
            #expect(
                Calendar.current.isDate(workout.scheduledDate, inSameDayAs: expected),
                "Workout at index \(index) not shifted correctly"
            )
        }
    }

    @Test("shiftMissedWorkoutsForward does not move completed workouts")
    func shiftIgnoresCompletedWorkouts() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()
        let plan = try makePlan(container: container, profile: profile, startDate: today.adding(weeks: -2))

        let future = futureNonRestWorkouts(in: plan, from: today)
        guard let firstFuture = future.first else { return }

        // Mark the first future workout as completed
        firstFuture.isCompleted = true
        let completedDate = firstFuture.scheduledDate

        try container.planLifecycle.shiftMissedWorkoutsForward(plan: plan, by: 3, context: context)

        // The completed workout should not have moved
        #expect(Calendar.current.isDate(firstFuture.scheduledDate, inSameDayAs: completedDate))
    }

    @Test("shiftMissedWorkoutsForward does not move rest workouts")
    func shiftIgnoresRestWorkouts() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()
        let plan = try makePlan(container: container, profile: profile, startDate: today.adding(weeks: -2))

        let restWorkouts = (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter { $0.workoutType == .rest && $0.scheduledDate >= today }
        let restDates = restWorkouts.map { $0.scheduledDate }
        guard !restDates.isEmpty else { return }

        try container.planLifecycle.shiftMissedWorkoutsForward(plan: plan, by: 3, context: context)

        for (index, workout) in restWorkouts.enumerated() {
            #expect(
                Calendar.current.isDate(workout.scheduledDate, inSameDayAs: restDates[index]),
                "Rest workout should not have been shifted"
            )
        }
    }

    @Test("shiftMissedWorkoutsForward with days=0 is a no-op")
    func shiftZeroDaysIsNoOp() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()
        let plan = try makePlan(container: container, profile: profile, startDate: today.adding(weeks: -2))

        let before = futureNonRestWorkouts(in: plan, from: today)
        let originalDates = before.map { $0.scheduledDate }

        try container.planLifecycle.shiftMissedWorkoutsForward(plan: plan, by: 0, context: context)

        for (index, workout) in before.enumerated() {
            #expect(
                Calendar.current.isDate(workout.scheduledDate, inSameDayAs: originalDates[index]),
                "Workout should not move when days=0"
            )
        }
    }

    @Test("shiftMissedWorkoutsForward extends plan.endDate when shifted workouts fall beyond it")
    func shiftExtendsPlanEndDate() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()
        let plan = try makePlan(container: container, profile: profile, startDate: today.adding(weeks: -2))

        let originalEndDate = plan.endDate

        // Shift by a large number to guarantee the last workout goes past endDate
        try container.planLifecycle.shiftMissedWorkoutsForward(plan: plan, by: 30, context: context)

        let allFuture = futureNonRestWorkouts(in: plan, from: today)
        if let lastWorkout = allFuture.last {
            if lastWorkout.scheduledDate > originalEndDate {
                #expect(plan.endDate >= lastWorkout.scheduledDate)
            }
        }
    }

    // MARK: rebuildPlan

    @Test("rebuildPlan retires the old plan and creates a new active plan")
    func rebuildRetiresOldAndCreatesNew() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()
        let oldPlan = try makePlan(container: container, profile: profile, startDate: today.adding(weeks: -2))
        let oldPlanID = oldPlan.id

        try container.planLifecycle.rebuildPlan(replacing: oldPlan, profile: profile, context: context)

        let allPlans = try container.planRepository.fetchAll()
        // N1: the replaced plan is kept as history, not deleted.
        #expect(allPlans.count == 2)
        #expect(allPlans.filter(\.isActive).count == 1)
        #expect(allPlans.first(where: { $0.id == oldPlanID })?.isActive == false)
        let active = try container.planRepository.fetchActivePlan()
        #expect(active != nil)
        #expect(active?.id != oldPlanID)
    }

    @Test("rebuildPlan preserves the replaced plan's completed workouts as history")
    func rebuildPreservesCompletedHistory() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()
        let oldPlan = try makePlan(container: container, profile: profile, startDate: today.adding(weeks: -2))

        // Complete one of the plan's workouts so the block carries real history.
        let pastWorkouts = (oldPlan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter { $0.workoutType.isRunType }
            .sorted { $0.scheduledDate < $1.scheduledDate }
        guard let completed = pastWorkouts.first else {
            Issue.record("Generated plan had no run workouts to complete")
            return
        }
        let run = RunWorkout(
            date: completed.scheduledDate,
            distanceMeters: 5_000,
            durationSeconds: 1_500,
            workoutType: .easy
        )
        context.insert(run)
        completed.completedWorkout = run
        completed.isCompleted = true
        try context.save()

        try container.planLifecycle.rebuildPlan(replacing: oldPlan, profile: profile, context: context)

        // The old block, its weeks, its completed day, and the run's link all survive.
        #expect(oldPlan.hasLoggedProgress == true)
        #expect(completed.isCompleted == true)
        #expect(run.scheduledWorkout?.id == completed.id)
        let storedRuns = try context.fetch(FetchDescriptor<RunWorkout>())
        #expect(storedRuns.contains { $0.id == run.id })
    }

    @Test("shiftMissedWorkoutsForward moves strength days with the runs")
    func shiftMovesStrengthWorkouts() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        profile.selectedEquipment = [.bodyweight]
        let today = Date()
        let plan = try makePlan(container: container, profile: profile, startDate: today.adding(weeks: -2))

        let startOfToday = Calendar.current.startOfDay(for: today)
        let strength = (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter { $0.workoutType == .strength && !$0.isCompleted && $0.scheduledDate >= startOfToday }
        guard !strength.isEmpty else { return }
        let originalDates = strength.map(\.scheduledDate)

        try container.planLifecycle.shiftMissedWorkoutsForward(plan: plan, by: 4, context: context)

        // N6: holding strength still while runs slid past it dropped runs onto gym
        // days, and the plan's duplicate pruning then deleted the gym session.
        for (index, workout) in strength.enumerated() {
            let expected = Calendar.current.date(byAdding: .day, value: 4, to: originalDates[index])
            #expect(
                expected.map { Calendar.current.isDate(workout.scheduledDate, inSameDayAs: $0) } == true,
                "Strength workout at index \(index) should shift with the runs"
            )
        }
    }

    @Test("shiftMissedWorkoutsForward never moves a session onto or past a fixed race date")
    func shiftIsClampedByRaceDate() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()
        let raceDate = today.startOfDay.adding(days: 21)

        let plan = container.trainingPlanService.generateRacePlan(
            profile: profile,
            startDate: today.adding(weeks: -2),
            raceDate: raceDate,
            raceName: "Test Race",
            runDayIndices: [0, 2, 4, 5]
        )
        try container.planRepository.save(plan)

        let raceWorkouts = (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter { $0.workoutType == .race }
        let raceDates = raceWorkouts.map(\.scheduledDate)

        // Far more than the block has room for: unclamped this pushed the whole
        // remaining plan over race day (N6).
        let outcome = try container.planLifecycle.shiftMissedWorkoutsForward(plan: plan, by: 60, context: context)

        #expect(outcome.requestedDays == 60)
        #expect(outcome.wasClampedByRace)
        #expect(outcome.appliedDays < 60)

        let startOfRaceDay = Calendar.current.startOfDay(for: raceDate)
        let movable = (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter { !$0.isCompleted && $0.workoutType != .rest && $0.workoutType != .race }
        for workout in movable {
            #expect(
                workout.scheduledDate < startOfRaceDay,
                "A \(workout.workoutType) session landed on or after race day"
            )
        }

        // The race itself is excluded from the shift and must not have drifted.
        for (index, workout) in raceWorkouts.enumerated() {
            #expect(Calendar.current.isDate(workout.scheduledDate, inSameDayAs: raceDates[index]))
        }
    }

    @Test("rebuildPlan uses generateRacePlan when plan has a raceDate")
    func rebuildWithRaceDateUsesRacePlan() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()

        let raceDate = date(2027, 4, 1)
        let plan = container.trainingPlanService.generateRacePlan(
            profile: profile,
            startDate: today.adding(weeks: -2),
            raceDate: raceDate,
            raceName: "Test Race",
            runDayIndices: [0, 2, 4, 5]
        )
        try container.planRepository.save(plan)

        try container.planLifecycle.rebuildPlan(replacing: plan, profile: profile, context: context)

        let newPlan = try container.planRepository.fetchActivePlan()
        #expect(newPlan != nil)
        #expect(newPlan?.raceName == "Test Race")
        // New plan should still target the same race date
        if let newRaceDate = newPlan?.raceDate {
            #expect(Calendar.current.isDate(newRaceDate, inSameDayAs: raceDate))
        }
    }

    @Test("rebuildPlan preserves goalTimeSeconds and targetRace from old plan")
    func rebuildPreservesGoalMetadata() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()

        let oldPlan = try makePlan(container: container, profile: profile, startDate: today.adding(weeks: -2))
        oldPlan.goalTimeSeconds = 5_400  // 90 min
        oldPlan.targetRace = .halfMarathon

        try container.planLifecycle.rebuildPlan(replacing: oldPlan, profile: profile, context: context)

        let newPlan = try container.planRepository.fetchActivePlan()
        #expect(newPlan?.goalTimeSeconds == 5_400)
        #expect(newPlan?.targetRace == .halfMarathon)
    }

    @Test("rebuildPlan starts new plan from today")
    func rebuildStartsFromToday() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()

        let oldPlan = try makePlan(container: container, profile: profile, startDate: today.adding(weeks: -4))

        try container.planLifecycle.rebuildPlan(replacing: oldPlan, profile: profile, context: context)

        let newPlan = try container.planRepository.fetchActivePlan()
        #expect(newPlan != nil)
        // New plan should start on or after today
        if let startDate = newPlan?.startDate {
            #expect(startDate >= today.startOfDay)
        }
    }
}
