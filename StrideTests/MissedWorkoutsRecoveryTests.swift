import Foundation
import SwiftData
import Testing
@testable import Stride

@MainActor
struct MissedWorkoutsRecoveryTests {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
    }

    private func makeContainer() -> AppContainer {
        AppContainer.preview()
    }

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

        try container.shiftMissedWorkoutsForward(plan: plan, by: 5, context: context)

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

        try container.shiftMissedWorkoutsForward(plan: plan, by: 3, context: context)

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

        try container.shiftMissedWorkoutsForward(plan: plan, by: 3, context: context)

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

        try container.shiftMissedWorkoutsForward(plan: plan, by: 0, context: context)

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
        try container.shiftMissedWorkoutsForward(plan: plan, by: 30, context: context)

        let allFuture = futureNonRestWorkouts(in: plan, from: today)
        if let lastWorkout = allFuture.last {
            if lastWorkout.scheduledDate > originalEndDate {
                #expect(plan.endDate >= lastWorkout.scheduledDate)
            }
        }
    }

    // MARK: rebuildPlan

    @Test("rebuildPlan deletes old plan and creates a new active plan")
    func rebuildDeletesOldAndCreatesNew() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext
        let profile = makeProfile(in: context)
        let today = Date()
        let oldPlan = try makePlan(container: container, profile: profile, startDate: today.adding(weeks: -2))

        try container.rebuildPlan(replacing: oldPlan, profile: profile, context: context)

        let allPlans = try container.planRepository.fetchAll()
        #expect(allPlans.count == 1)
        #expect(allPlans.first?.isActive == true)
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

        try container.rebuildPlan(replacing: plan, profile: profile, context: context)

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

        try container.rebuildPlan(replacing: oldPlan, profile: profile, context: context)

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

        try container.rebuildPlan(replacing: oldPlan, profile: profile, context: context)

        let newPlan = try container.planRepository.fetchActivePlan()
        #expect(newPlan != nil)
        // New plan should start on or after today
        if let startDate = newPlan?.startDate {
            #expect(startDate >= today.startOfDay)
        }
    }
}
