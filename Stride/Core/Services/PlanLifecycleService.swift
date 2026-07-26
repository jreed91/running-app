import Foundation
import SwiftData

/// Everything that creates, moves, replaces, or destroys a training plan.
///
/// These five operations were methods on `AppContainer` (D2). They belong together and
/// they do not belong in the dependency-injection root: each one has to reach past the
/// store to the two things a plan owns outside it — its WorkoutKit entries on the Watch
/// and its scheduled morning reminders — and getting that order wrong is what N1, N11,
/// and D3 were all about. Collecting them behind one type makes the ordering rules
/// reviewable in one file, and gives the container one property instead of five methods.
///
/// The date arithmetic underneath is already pure and tested elsewhere:
/// `MissedWorkoutShift` resolves how far a shift can actually travel, and
/// `PlanRebuildWindow` decides how many weeks a rebuild covers.
@MainActor
final class PlanLifecycleService {
    private let trainingPlanService: TrainingPlanService
    private let planRepository: PlanRepositoryProtocol
    private let healthKitRepository: HealthKitRepositoryProtocol
    private let notificationService: NotificationService

    init(
        trainingPlanService: TrainingPlanService,
        planRepository: PlanRepositoryProtocol,
        healthKitRepository: HealthKitRepositoryProtocol,
        notificationService: NotificationService
    ) {
        self.trainingPlanService = trainingPlanService
        self.planRepository = planRepository
        self.healthKitRepository = healthKitRepository
        self.notificationService = notificationService
    }

    // MARK: - Continuous plan refresh

    /// Re-derives training paces from recent history and updates all future uncompleted
    /// workouts in the plan. Call this after the user completes any run so workout
    /// targets stay aligned with their current VDOT for any number of weekly run days.
    func refreshPlanAfterWorkout(
        plan: TrainingPlan,
        history: [RunWorkout],
        profile: UserProfile,
        unitPreference: UnitPreference = .metric
    ) {
        trainingPlanService.refreshPaces(
            plan: plan,
            history: history,
            profile: profile,
            unitPreference: unitPreference
        )
    }

    // MARK: - Missed workout recovery

    /// Shifts all future uncompleted training workouts forward by `days` calendar days.
    /// Extends `plan.endDate` if any shifted workout falls beyond it.
    /// Race workouts are excluded when the plan has a fixed raceDate.
    ///
    /// Strength and cross-training move with the runs. Holding them still while the
    /// runs slid past them dropped runs onto gym days, and the plan's same-day
    /// duplicate pruning then deleted the strength session outright (N6). Shifting
    /// the whole week by one delta preserves the spacing the plan was built with —
    /// which is the point of "pick up where I left off". Rest days stay put: they
    /// are gaps, not sessions, and nothing is lost by leaving them.
    ///
    /// Holding the race still was never enough on its own: the rest of the block slid
    /// straight over it, so a runner four days behind could end up with a tempo session
    /// on race morning. `MissedWorkoutShift` clamps the request to the room that exists
    /// before race day, and the returned outcome tells the caller how much of the
    /// request survived so the UI can say so.
    ///
    /// - Returns: What the shift resolved to. `Outcome.isNoOp` means nothing moved and
    ///   nothing was saved.
    @discardableResult
    func shiftMissedWorkoutsForward(
        plan: TrainingPlan,
        by days: Int,
        context: ModelContext
    ) throws -> MissedWorkoutShift.Outcome {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let hasFixedRace = plan.raceDate != nil

        let allWorkouts: [ScheduledWorkout] = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }
        let toShift: [ScheduledWorkout] = allWorkouts.filter { w in
            guard !w.isCompleted else { return false }
            guard w.scheduledDate >= startOfToday else { return false }
            let type = w.workoutType
            if type == .rest { return false }
            if hasFixedRace && type == .race { return false }
            return true
        }

        let outcome = MissedWorkoutShift.resolve(
            requestedDays: days,
            lastMovableDate: toShift.map(\.scheduledDate).max(),
            raceDate: plan.raceDate
        )
        guard !outcome.isNoOp else { return outcome }

        for workout in toShift {
            workout.scheduledDate = Calendar.current.date(
                byAdding: .day, value: outcome.appliedDays, to: workout.scheduledDate
            ) ?? workout.scheduledDate
        }

        if let newLast = toShift.max(by: { $0.scheduledDate < $1.scheduledDate }),
           newLast.scheduledDate > plan.endDate {
            plan.endDate = newLast.scheduledDate
        }

        try context.save()
        return outcome
    }

    // MARK: - Rebuild

    /// Retires the active plan and generates a fresh one starting from today,
    /// preserving the original race date, goal time, and race type.
    ///
    /// The plan being replaced is **deactivated, never deleted** (N1). Deleting it
    /// cascaded through its weeks and every `ScheduledWorkout` in them, including
    /// completed ones — erasing the block from Plan History and unlinking the runs
    /// that fulfilled it. That is the same data loss H3 fixed for the plan-creation
    /// flows, and it fired from a button the app offers a runner who has fallen
    /// behind. Deleting a plan stays a deliberate action in the Plan History list.
    func rebuildPlan(
        replacing oldPlan: TrainingPlan,
        profile: UserProfile,
        context: ModelContext,
        unitPreference: UnitPreference = .metric
    ) throws {
        let startDate = Date().startOfDay
        let runDayIndices = profile.preferredRunDayIndices

        let newPlan: TrainingPlan
        if let raceDate = oldPlan.raceDate, let raceName = oldPlan.raceName {
            newPlan = trainingPlanService.generateRacePlan(
                profile: profile,
                startDate: startDate,
                raceDate: raceDate,
                raceName: raceName,
                runDayIndices: runDayIndices,
                unitPreference: unitPreference
            )
        } else {
            newPlan = trainingPlanService.generatePlan(
                profile: profile,
                startDate: startDate,
                numberOfWeeks: PlanRebuildWindow.remainingWeeks(from: startDate, to: oldPlan.endDate),
                runDayIndices: runDayIndices,
                unitPreference: unitPreference
            )
        }

        newPlan.goalTimeSeconds = oldPlan.goalTimeSeconds
        newPlan.targetRace = oldPlan.targetRace

        // `save` enforces the single-active invariant by deactivating every other
        // plan, which retires `oldPlan` while keeping it (and its history) in the store.
        try planRepository.save(newPlan)
        try planRepository.setActive(newPlan)

        // The scheduler only clears entries for the plan it is syncing, so the retired
        // plan's workouts would otherwise stay on the Watch alongside the new block's.
        // Fire-and-forget: a failure here must not fail the rebuild the user asked for.
        Task { @MainActor [healthKitRepository] in
            try? await healthKitRepository.removeWorkoutPlans(for: oldPlan)
        }
    }

    // MARK: - Plan deletion

    /// Everything deliberately deleting one plan has to tear down, in one place (D3).
    ///
    /// A plan owns state outside its own row: WorkoutKit entries on the Watch and in
    /// Fitness, and up to 56 scheduled morning reminders. Both are reachable only
    /// *through* the plan, so deleting the record first strands them — still scheduled,
    /// with nothing left to find them from. That is the same orphaning N1 fixed for the
    /// rebuild path and N11 for the full reset; this is the third and last place a plan
    /// is deliberately destroyed.
    ///
    /// It had two copies, in the Plan History swipe and the plan detail dialog, each
    /// correct and each independently maintained. `resetAllData` is a fourth statement of
    /// the same order of operations, over every plan at once. `PlanRepository` has no
    /// `delete` of its own precisely so this stays the only way to remove a plan.
    ///
    /// Best-effort on the teardown steps: an unauthorized or unsupported scheduler must
    /// not block the deletion the user explicitly confirmed.
    func deletePlan(_ plan: TrainingPlan, context: ModelContext) async {
        try? await healthKitRepository.removeWorkoutPlans(for: plan)
        notificationService.cancelReminders(for: plan)
        context.delete(plan)
        context.saveOrLog("a deleted plan")
    }

    // MARK: - Reset

    /// Everything **Settings → Reset All Data** has to tear down, in one place (N11).
    ///
    /// Deleting the SwiftData rows was only the visible half of a reset. Left behind,
    /// each of these outlives the data it describes:
    ///
    /// - up to 56 pending morning reminders keep firing for a plan that no longer exists;
    /// - the plan's WorkoutKit entries stay on the Watch and in Fitness, so the app
    ///   drops to onboarding while the Watch still offers last week's workouts;
    /// - the pending-review pointer and its snapshot can re-insert a deleted run on
    ///   the next launch, which is a reset that undoes itself.
    ///
    /// Order matters: the Watch entries are found through the plans that own them, so
    /// they have to be removed *before* the models are deleted. The in-memory pointer at
    /// the review sheet is the container's, and it is cleared by the caller *before* this
    /// runs so nothing is holding a deleted model while the rows go.
    func resetAllData(context: ModelContext) async {
        await notificationService.cancelAllMorningReminders()

        let plans = (try? context.fetch(FetchDescriptor<TrainingPlan>())) ?? []
        for plan in plans {
            // Best-effort per plan: an unauthorized or unsupported scheduler must not
            // stop the reset the user explicitly confirmed.
            try? await healthKitRepository.removeWorkoutPlans(for: plan)
        }

        NotificationService.clearAllReviewState()

        do {
            try context.delete(model: RunWorkout.self)
            try context.delete(model: StrengthWorkout.self)
            try context.delete(model: ScheduledWorkout.self)
            try context.delete(model: TrainingWeek.self)
            try context.delete(model: TrainingPlan.self)
            try context.delete(model: UserProfile.self)
            try context.delete(model: SavedRoute.self)
            try context.delete(model: DeletedWorkout.self)
            try context.save()
            AppLogger.log("Reset All Data completed for \(plans.count) plan(s).", label: "Data", level: .notice)
        } catch {
            AppLogger.log("Reset All Data failed: \(error)", label: "Data", level: .error)
        }
    }
}
