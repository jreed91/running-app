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
    /// Sessions the runner changed on purpose in the last week are left alone
    /// (``AdaptedSessions``, P1.1).
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
            unitPreference: unitPreference,
            // A training break's sessions too: the refresh would rewrite the note that
            // says why they're shorter, and a break outlasts the week an edit is kept.
            protectedSessionIDs: AdaptedSessions.protectedIDs().union(TrainingBreakStore.protectedIDs())
        )
    }

    /// The same refresh for runs that arrive from Apple Health: the Watch, the Workout
    /// app, or another app. Only runs recorded in Stride used to move the plan's paces, so
    /// a runner who records on the Watch kept the paces of their last phone run (P1.1).
    /// Saves, then re-files the sessions already in the Workout app.
    ///
    /// The re-file is left running rather than awaited: the import calls this before it
    /// sends the "Run synced" banner, and a background wake's budget is short (P2.6).
    func refreshPlanAfterImport(context: ModelContext, unitPreference: UnitPreference) {
        guard let plan = try? planRepository.fetchActivePlan(),
              let profile = Self.latestProfile(in: context)
        else { return }
        // Runs only: this history re-derives the plan's pace targets (N38).
        // Numbers only: the pace refresh reads splits of its last few weeks, which fault in per run.
        let history = (try? context.fetch(RunWorkout.summary(RunWorkout.runsOnlyDescriptor()))) ?? []
        refreshPlanAfterWorkout(plan: plan, history: history, profile: profile, unitPreference: unitPreference)
        context.saveOrLog("training paces refreshed after an imported run")
        Task { @MainActor in
            await self.refileRepacedSessions(in: plan, unitPreference: unitPreference, context: context)
        }
    }

    private static func latestProfile(in context: ModelContext) -> UserProfile? {
        var descriptor = FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Re-files the sessions the refresh just re-paced that are already in the Workout app.
    ///
    /// The refresh rewrites every future session in place, but the Workout app kept the
    /// copies filed before it until the next full sync on a cold launch, so the Watch ran
    /// last week's paces (P2.4). Edits only, through the single-workout sync: a session
    /// that was never filed stays out, and nothing here asks for WorkoutKit authorization.
    func refileRepacedSessions(in plan: TrainingPlan, unitPreference: UnitPreference, context: ModelContext) async {
        // A protected session was not re-paced, so its filed copy is already current.
        let unchanged = AdaptedSessions.protectedIDs().union(TrainingBreakStore.protectedIDs())
        let sessions = Self.repacedSessionsOnTheWatch(in: plan, now: Date())
            .filter { !unchanged.contains($0.id) }
        guard !sessions.isEmpty else { return }
        for session in sessions {
            try? await healthKitRepository.syncWorkoutPlan(for: session, unitPreference: unitPreference)
        }
        context.saveOrLog("the re-paced sessions' Watch workout ids")
    }

    /// The sessions ``refileRepacedSessions(in:unitPreference:context:)`` re-files: filed
    /// with the Workout app, not completed, and after today, which is exactly what
    /// `refreshPaces` rewrites. Soonest first, so the sessions that matter go first.
    static func repacedSessionsOnTheWatch(
        in plan: TrainingPlan,
        now: Date,
        calendar: Calendar = .current
    ) -> [ScheduledWorkout] {
        let today = calendar.startOfDay(for: now)
        return (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter { $0.healthKitPlanID != nil && !$0.isCompleted && $0.scheduledDate > today }
            .sorted { $0.scheduledDate < $1.scheduledDate }
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

    // MARK: - Start Running

    /// Runs this week's Start Running stage again next week
    /// (``StartRunningPlanService/repeatWeek(in:profile:now:)``), then re-files the plan
    /// with the Watch and re-schedules the morning reminders, both of which hold the dates
    /// the later weeks just moved off.
    ///
    /// - Returns: False, having changed nothing, when the week can't be repeated.
    /// - Throws: Whatever the save throws, after putting the plan back as it was.
    @discardableResult
    func repeatStartRunningWeek(
        plan: TrainingPlan,
        profile: UserProfile,
        context: ModelContext,
        morningRemindersEnabled: Bool,
        unitPreference: UnitPreference = .metric
    ) throws -> Bool {
        guard let repeated = StartRunningPlanService().repeatWeek(in: plan, profile: profile) else {
            return false
        }
        context.insert(repeated)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        Task { @MainActor [healthKitRepository, notificationService] in
            if morningRemindersEnabled {
                await notificationService.scheduleMorningReminders(for: plan)
            }
            try? await healthKitRepository.syncWorkoutPlans(for: plan, unitPreference: unitPreference)
            context.saveOrLog("the repeated week's WorkoutKit ids")
        }
        return true
    }

    // MARK: - Training breaks

    /// Writes a training break into the plan (``TrainingBreakApplier/start``), then
    /// re-files the changed sessions with the Watch and re-schedules the morning reminders.
    /// The whole set of reminders, not one: a run turned into a rest day has to lose its
    /// reminder, and a single re-schedule never removes one.
    @discardableResult
    func startTrainingBreak(
        _ proposal: TrainingBreakPlanner.Proposal,
        plan: TrainingPlan,
        history: [RunWorkout],
        profile: UserProfile,
        context: ModelContext,
        morningRemindersEnabled: Bool,
        unitPreference: UnitPreference = .metric
    ) throws -> TrainingBreak {
        let (record, changed) = try TrainingBreakApplier.start(
            proposal,
            in: plan,
            context: context,
            history: history,
            profile: profile,
            unitPreference: unitPreference,
            service: trainingPlanService
        )
        refile(changed, in: plan, context: context, morningRemindersEnabled: morningRemindersEnabled, unitPreference: unitPreference)
        return record
    }

    /// Puts the plan back the way it was before the break.
    func undoTrainingBreak(
        _ trainingBreak: TrainingBreak,
        plan: TrainingPlan,
        context: ModelContext,
        morningRemindersEnabled: Bool,
        unitPreference: UnitPreference = .metric
    ) {
        let changed = TrainingBreakApplier.undo(trainingBreak, in: plan, context: context)
        refile(changed, in: plan, context: context, morningRemindersEnabled: morningRemindersEnabled, unitPreference: unitPreference)
    }

    /// "I'm back": the rest of the break goes back as planned and the runner eases in
    /// from today.
    func endTrainingBreakEarly(
        _ trainingBreak: TrainingBreak,
        plan: TrainingPlan,
        history: [RunWorkout],
        profile: UserProfile,
        context: ModelContext,
        morningRemindersEnabled: Bool,
        unitPreference: UnitPreference = .metric
    ) {
        let changed = TrainingBreakApplier.endEarly(
            trainingBreak,
            in: plan,
            context: context,
            history: history,
            profile: profile,
            unitPreference: unitPreference,
            service: trainingPlanService
        )
        refile(changed, in: plan, context: context, morningRemindersEnabled: morningRemindersEnabled, unitPreference: unitPreference)
    }

    /// Left running rather than awaited, like ``repeatStartRunningWeek``: the plan is
    /// saved, and a slow or unauthorized scheduler must not hold up the screen.
    private func refile(
        _ sessions: [ScheduledWorkout],
        in plan: TrainingPlan,
        context: ModelContext,
        morningRemindersEnabled: Bool,
        unitPreference: UnitPreference
    ) {
        guard !sessions.isEmpty else { return }
        let soonestFirst = sessions.sorted { $0.scheduledDate < $1.scheduledDate }
        Task { @MainActor [healthKitRepository, notificationService] in
            if morningRemindersEnabled {
                await notificationService.scheduleMorningReminders(for: plan)
            }
            for session in soonestFirst {
                try? await healthKitRepository.syncWorkoutPlan(for: session, unitPreference: unitPreference)
            }
            context.saveOrLog("the training break's Watch workout ids")
        }
    }

    // MARK: - Activation

    /// Commits a freshly generated plan as *the* active plan, and hands its off-store
    /// integrations to a task that does not gate the caller.
    ///
    /// Every creation screen had its own copy of this, and every copy did the same two
    /// things — which is what left the setup sheets spinning when a plan was already
    /// active:
    ///
    /// 1. The new plan was inserted **and saved** while the previous one was still
    ///    `isActive`, so the store briefly held two active plans. That is a state the app
    ///    reacts to: `StrideApp`'s `.task(id: activePlans.first?.id)` deduplicates and then
    ///    re-syncs the active plan to WorkoutKit, so a second full `WorkoutScheduler` pass
    ///    started racing the one the sheet was already running — over the same workouts, on
    ///    the same actor. Retiring before the save means no observer ever sees two.
    /// 2. The sheet's spinner was cleared only *after* awaiting a WorkoutKit removal for
    ///    every plan in the store and a full re-sync of the new one. On a plan the length of
    ///    a pregnancy that is hundreds of serialized scheduler round trips, and anything
    ///    that stalls in there has no way out: the sheet spins with the runner's plan
    ///    already saved behind it.
    ///
    /// So the store work is synchronous and complete when this returns — the plan is
    /// active, the previous ones are retired (deactivated, never deleted: H3/N1), and it
    /// is all in one save — while the Watch entries and the morning reminders follow in a
    /// detached task. That is the same fire-and-forget rule `rebuildPlan` already applies
    /// for the same reason: a scheduler that is slow, unauthorized, or wedged must not be
    /// able to fail — or hold up — the plan the runner asked for.
    ///
    /// - Throws: Whatever the save throws. The plan is *not* left inserted in that case,
    ///   and any plan retired for it is put back, so a failed attempt changes nothing.
    func activateNewPlan(
        _ plan: TrainingPlan,
        context: ModelContext,
        morningRemindersEnabled: Bool,
        unitPreference: UnitPreference = .metric
    ) throws {
        // Read before the insert, and `try` rather than `try?`: a fetch that failed
        // silently would leave the previous plan active alongside the new one, which is
        // exactly the state this method exists to never produce.
        let previous = try context.fetch(FetchDescriptor<TrainingPlan>())
            .filter { $0.id != plan.id }
        let retired = previous.filter(\.isActive)

        retired.forEach { $0.isActive = false }
        plan.isActive = true
        context.insert(plan)

        do {
            try context.save()
        } catch {
            context.delete(plan)
            retired.forEach { $0.isActive = true }
            throw error
        }

        Task { @MainActor [healthKitRepository, notificationService] in
            if morningRemindersEnabled {
                await notificationService.scheduleMorningReminders(for: plan)
            }
            // Every previous plan, not just the retired one: the scheduler only clears the
            // entries of the plan it is syncing, and a plan retired by launch-time dedup
            // never had a removal pass of its own.
            for old in previous {
                try? await healthKitRepository.removeWorkoutPlans(for: old)
            }
            try? await healthKitRepository.syncWorkoutPlans(
                for: plan,
                unitPreference: unitPreference
            )
            context.saveOrLog("the new plan's WorkoutKit ids")
        }
    }

    // MARK: - Rebuild

    /// Retires the active plan and generates a fresh one starting from today,
    /// preserving the original race date, goal time, and race type. A Start Running plan
    /// restarts at the last stage the runner ran; a pregnancy plan is rebuilt from the due
    /// date on the profile.
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
        recentVolume: RecentRunningVolume? = nil,
        unitPreference: UnitPreference = .metric
    ) throws {
        let startDate = Date().startOfDay
        let runDayIndices = profile.preferredRunDayIndices

        // A plan built by another generator is rebuilt by that generator. Falling through
        // to the race-plan path turned a pregnancy or Start Running plan into a VDOT race
        // plan with pace bands, the one thing either kind must never become.
        switch oldPlan.planKind {
        case .startRunning:
            let newPlan = StartRunningPlanService().generatePlan(
                profile: profile,
                startDate: startDate,
                firstStage: StartRunningPlanService.resumeStage(for: oldPlan)
            )
            try activateRebuilt(newPlan, replacing: oldPlan)
            return
        case .pregnancy:
            // Throws when the due date has passed or the screening is missing, which the
            // rebuild surfaces as its failure alert rather than building something else.
            let newPlan = try PregnancyPlanService().generatePlan(profile: profile, startDate: startDate)
            try activateRebuilt(newPlan, replacing: oldPlan)
            return
        case .standard:
            break
        }

        let newPlan: TrainingPlan
        if let raceDate = oldPlan.raceDate, let raceName = oldPlan.raceName {
            newPlan = trainingPlanService.generateRacePlan(
                profile: profile,
                startDate: startDate,
                raceDate: raceDate,
                raceName: raceName,
                runDayIndices: runDayIndices,
                recentVolume: recentVolume,
                unitPreference: unitPreference
            )
        } else {
            newPlan = trainingPlanService.generatePlan(
                profile: profile,
                startDate: startDate,
                numberOfWeeks: PlanRebuildWindow.remainingWeeks(from: startDate, to: oldPlan.endDate),
                runDayIndices: runDayIndices,
                recentVolume: recentVolume,
                unitPreference: unitPreference
            )
        }

        newPlan.goalTimeSeconds = oldPlan.goalTimeSeconds
        newPlan.targetRace = oldPlan.targetRace
        try activateRebuilt(newPlan, replacing: oldPlan)
    }

    private func activateRebuilt(_ newPlan: TrainingPlan, replacing oldPlan: TrainingPlan) throws {
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
        // The nudges name a streak, a plan and a week that are all about to stop
        // existing, and their delivery marks live in UserDefaults rather than the store
        // being torn down — so without this, the first evening after a reset is silent
        // for a reason that no longer applies (A9).
        await notificationService.cancelTrainingNudges(includingLog: true)

        do {
            try context.delete(model: RunWorkout.self)
            try context.delete(model: StrengthWorkout.self)
            try context.delete(model: ScheduledWorkout.self)
            try context.delete(model: TrainingWeek.self)
            try context.delete(model: TrainingPlan.self)
            try context.delete(model: UserProfile.self)
            try context.delete(model: SavedRoute.self)
            try context.delete(model: SavedWorkout.self)
            try context.delete(model: DeletedWorkout.self)
            try context.delete(model: Shoe.self)
            try context.save()
            AppLogger.log("Reset All Data completed for \(plans.count) plan(s).", label: "Data", level: .notice)
        } catch {
            AppLogger.log("Reset All Data failed: \(error)", label: "Data", level: .error)
        }
    }
}
