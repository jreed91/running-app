import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers the plan-history-preservation invariants behind H3: a plan with completed
/// work must be recognisable as history (`hasLoggedProgress`) so plan creation
/// deactivates rather than deletes it, and the repository must keep exactly one
/// active plan.
@MainActor
struct PlanHistoryTests {

    private func makePlan(
        in context: ModelContext,
        completeFirstWorkout: Bool,
        isActive: Bool = false
    ) throws -> TrainingPlan {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: start,
            endDate: start.addingTimeInterval(6 * 86_400)
        )
        plan.isActive = isActive
        context.insert(plan)

        let week = TrainingWeek(weekNumber: 1, startDate: start, phase: .base, targetDistanceKm: 13)
        context.insert(week)
        week.plan = plan

        let easy = ScheduledWorkout(scheduledDate: start, workoutType: .easy, targetDistanceMeters: 5_000)
        let rest = ScheduledWorkout(scheduledDate: start.addingTimeInterval(86_400), workoutType: .rest)
        context.insert(easy)
        context.insert(rest)
        easy.week = week
        rest.week = week

        if completeFirstWorkout {
            let run = RunWorkout(date: start, distanceMeters: 5_000, durationSeconds: 1_500, workoutType: .easy)
            context.insert(run)
            easy.completedWorkout = run
            easy.isCompleted = true
        }

        try context.save()
        return plan
    }

    @Test("hasLoggedProgress is true only once a non-rest workout is completed")
    func hasLoggedProgressReflectsCompletion() throws {
        let context = TestStore.makeContext()

        let untouched = try makePlan(in: context, completeFirstWorkout: false)
        #expect(untouched.hasLoggedProgress == false)

        let started = try makePlan(in: context, completeFirstWorkout: true)
        #expect(started.hasLoggedProgress == true)
    }

    @Test("A completed rest day does not count as logged progress")
    func restCompletionIsNotProgress() throws {
        let context = TestStore.makeContext()
        let plan = try makePlan(in: context, completeFirstWorkout: false)

        // Mark only the rest day complete.
        let workouts = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }
        workouts.first { $0.workoutType == .rest }?.isCompleted = true
        try context.save()

        #expect(plan.hasLoggedProgress == false)
    }

    @Test("Saving an active plan deactivates every other plan")
    func saveEnforcesSingleActivePlan() throws {
        let container = TestStore.makeContainer()
        let context = container.modelContainer.mainContext

        let old = try makePlan(in: context, completeFirstWorkout: true, isActive: true)
        #expect(old.isActive == true)

        let new = TrainingPlan(
            targetRace: .halfMarathon,
            goalTimeSeconds: 5_400,
            startDate: Date(),
            endDate: Date().addingTimeInterval(6 * 86_400)
        ) // init sets isActive = true
        try container.planRepository.save(new)

        #expect(new.isActive == true)
        #expect(old.isActive == false)

        let actives = try context.fetch(
            FetchDescriptor<TrainingPlan>(predicate: #Predicate { $0.isActive })
        )
        #expect(actives.count == 1)
        #expect(actives.first?.id == new.id)
    }

    // MARK: - Creating a plan on top of an active one

    /// The service under test with a mock scheduler, so the fire-and-forget task
    /// `activateNewPlan` starts can never reach WorkoutKit from a unit-test host.
    private func makeLifecycle(context: ModelContext) -> PlanLifecycleService {
        PlanLifecycleService(
            trainingPlanService: TrainingPlanService(),
            planRepository: PlanRepository(context: context),
            healthKitRepository: MockHealthKitRepository(),
            notificationService: .shared
        )
    }

    @Test("activateNewPlan retires the previous plan in the same save")
    func activateNewPlanRetiresPreviousPlan() throws {
        let context = TestStore.makeContext()
        let lifecycle = makeLifecycle(context: context)

        let old = try makePlan(in: context, completeFirstWorkout: true, isActive: true)
        let new = TrainingPlan(
            targetRace: .halfMarathon,
            goalTimeSeconds: 5_400,
            startDate: Date(),
            endDate: Date().addingTimeInterval(6 * 86_400)
        )

        try lifecycle.activateNewPlan(new, context: context, morningRemindersEnabled: false)

        // The store work is complete when the call returns: the sheet that called this can
        // dismiss immediately, and the WorkoutKit pass it left running has nothing the user
        // is waiting on. This is the assertion that would fail if the awaits came back.
        #expect(context.hasChanges == false)

        // The invariant holds at every point an observer could look — no window in which
        // both plans read as active, which is what set `StrideApp`'s dedup-and-resync
        // racing the creation screen.
        let actives = try context.fetch(
            FetchDescriptor<TrainingPlan>(predicate: #Predicate { $0.isActive })
        )
        #expect(actives.count == 1)
        #expect(actives.first?.id == new.id)

        // The retired plan is kept as history, with its completed work (H3/N1).
        #expect(old.isActive == false)
        #expect(old.hasLoggedProgress == true)
        let allPlans = try context.fetch(FetchDescriptor<TrainingPlan>())
        #expect(allPlans.count == 2)
    }

    @Test("activateNewPlan works with no plan in the store")
    func activateNewPlanFromEmptyStore() throws {
        let context = TestStore.makeContext()
        let lifecycle = makeLifecycle(context: context)

        let new = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: Date(),
            endDate: Date().addingTimeInterval(6 * 86_400)
        )
        try lifecycle.activateNewPlan(new, context: context, morningRemindersEnabled: false)

        let actives = try context.fetch(
            FetchDescriptor<TrainingPlan>(predicate: #Predicate { $0.isActive })
        )
        #expect(actives.count == 1)
        #expect(actives.first?.id == new.id)
    }

    @Test("activateNewPlan leaves already-retired plans alone")
    func activateNewPlanDoesNotDisturbHistory() throws {
        let context = TestStore.makeContext()
        let lifecycle = makeLifecycle(context: context)

        let history = try makePlan(in: context, completeFirstWorkout: true, isActive: false)
        let active = try makePlan(in: context, completeFirstWorkout: false, isActive: true)

        let new = TrainingPlan(
            targetRace: .marathon,
            goalTimeSeconds: 14_400,
            startDate: Date(),
            endDate: Date().addingTimeInterval(6 * 86_400)
        )
        try lifecycle.activateNewPlan(new, context: context, morningRemindersEnabled: false)

        #expect(history.isActive == false)
        #expect(active.isActive == false)
        #expect(new.isActive == true)
        let allPlans = try context.fetch(FetchDescriptor<TrainingPlan>())
        #expect(allPlans.count == 3)
    }

    @Test("fetchActivePlan returns the most recently created active plan")
    func fetchActivePlanIsDeterministic() throws {
        let container = TestStore.makeContainer()
        let context = container.modelContainer.mainContext

        // Force a violated invariant: two actives with different creation dates.
        let older = try makePlan(in: context, completeFirstWorkout: false, isActive: true)
        older.createdAt = Date(timeIntervalSince1970: 1_000)
        let newer = try makePlan(in: context, completeFirstWorkout: false, isActive: true)
        newer.createdAt = Date(timeIntervalSince1970: 2_000)
        try context.save()

        let resolved = try container.planRepository.fetchActivePlan()
        #expect(resolved?.id == newer.id)
    }

    // MARK: - Launch-time duplicate-active dedup (N2)

    @Test("Duplicate active plans are deactivated, never deleted")
    func duplicateActivePlansAreRetiredNotDeleted() throws {
        let container = TestStore.makeContainer()
        let context = container.modelContainer.mainContext

        // The CloudKit multi-device shape: two active plans, both carrying real work.
        let newer = try makePlan(in: context, completeFirstWorkout: true, isActive: true)
        newer.createdAt = Date(timeIntervalSince1970: 2_000)
        let older = try makePlan(in: context, completeFirstWorkout: true, isActive: true)
        older.createdAt = Date(timeIntervalSince1970: 1_000)
        try context.save()

        let retired = ProfileRestoreDeduplicator.retireDuplicateActivePlans(
            [newer, older],   // caller passes newest-first
            in: context
        )

        #expect(retired == 1)
        #expect(newer.isActive == true)
        #expect(older.isActive == false)

        // Nothing was destroyed: both plans, and the completed work in them, survive.
        let allPlans = try context.fetch(FetchDescriptor<TrainingPlan>())
        #expect(allPlans.count == 2)
        #expect(older.hasLoggedProgress == true)
        let resolvedActive = try container.planRepository.fetchActivePlan()
        #expect(resolvedActive?.id == newer.id)
    }

    @Test("A single active plan is left alone")
    func singleActivePlanIsUntouched() throws {
        let context = TestStore.makeContext()

        let only = try makePlan(in: context, completeFirstWorkout: false, isActive: true)

        let retired = ProfileRestoreDeduplicator.retireDuplicateActivePlans([only], in: context)

        #expect(retired == 0)
        #expect(only.isActive == true)
    }

    // MARK: - Link targets (N1/N2 keep retired plans in the store)

    @Test("Imported workouts never link to a retired plan's days")
    func retiredPlanDaysAreNotLinkTargets() throws {
        let context = TestStore.makeContext()

        let active = try makePlan(in: context, completeFirstWorkout: false, isActive: true)
        let retired = try makePlan(in: context, completeFirstWorkout: false, isActive: false)

        let runDays = { (plan: TrainingPlan) -> ScheduledWorkout? in
            (plan.weeks ?? []).flatMap { $0.workouts ?? [] }.first { $0.workoutType.isRunType }
        }
        guard let activeDay = runDays(active), let retiredDay = runDays(retired) else {
            Issue.record("Test plans had no run-type scheduled workouts")
            return
        }

        #expect(WorkoutSyncService.belongsToLivePlan(activeDay) == true)
        #expect(WorkoutSyncService.belongsToLivePlan(retiredDay) == false)
    }

    @Test("A workout with no plan stays eligible for linking")
    func orphanedWorkoutIsStillEligible() {
        // Legacy/orphaned rows predate the relationship; excluding them would silently
        // stop linking on older stores.
        let orphan = ScheduledWorkout(scheduledDate: Date(), workoutType: .easy)
        #expect(WorkoutSyncService.belongsToLivePlan(orphan) == true)
    }
}
