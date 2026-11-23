import Foundation

// MARK: - AdaptableWorkoutSelector

/// Which of a plan's scheduled sessions the AI coach is allowed to rewrite.
///
/// Two screens ask this and used to answer it separately (D1): `PlanTabView` picked the
/// batch for **Smart Adapt**, and `RunSummaryView` picked the single next session for
/// **apply coach feedback**. The filters were written independently and had already
/// drifted apart in shape — one listed the types it excluded, the other the types it
/// allowed — while agreeing on the rule that matters, which is exactly the situation
/// that produces a silent divergence later.
///
/// The rule, in one place:
///
/// - **Run sessions only.** A gym or cross-training day is not the coach's to rewrite,
///   and a rest day is a gap rather than a session.
/// - **Never the race.** The race is the fixed point the whole block is built around —
///   the same reason `MissedWorkoutShift` refuses to move it.
/// - **Never a completed session.** Rewriting a workout the runner already did would
///   change the record of what they ran.
/// - **Today or later**, so adaptation edits the plan ahead rather than its history.
/// - **Not a training break's session.** A run a break shortened or turned into rest
///   (`TrainingBreakStore`) is the runner's choice; Smart Adapt would hand the tempo back
///   to someone who is ill.
enum AdaptableWorkoutSelector {

    /// Every session in `plan` the coach may adapt, earliest first.
    ///
    /// - Parameters:
    ///   - plan: The active plan. `nil` yields no candidates.
    ///   - after: An optional exclusive lower bound, used when the adaptation is a
    ///     reaction to a specific completed run: the session that run fulfilled must not
    ///     be a candidate for its own feedback, and neither must anything else scheduled
    ///     at or before it.
    ///   - now: The reference date; only its calendar day is used.
    ///   - excluding: Sessions a live training break changed.
    static func adaptableWorkouts(
        in plan: TrainingPlan?,
        after: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        excluding: Set<UUID> = TrainingBreakStore.protectedIDs()
    ) -> [ScheduledWorkout] {
        guard let plan else { return [] }

        // A pregnancy or Start Running plan is not the coach's to rewrite, for the same
        // reason it is not `refreshPaces`'s: its sessions are prescribed by effort and
        // duration, and an AI rewrite would hand them pace bands, intervals, and volume the
        // plan was built without. For Start Running the week-to-week progression *is* the
        // plan. Returning no candidates here disables both Smart Adapt and
        // apply-coach-feedback in one place.
        // See `docs/PREGNANCY_RUNNING_EVIDENCE.md` and `docs/START_RUNNING_PROGRAM.md`.
        guard !plan.prescribesByTime else { return [] }

        let today = calendar.startOfDay(for: now)

        return (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter { workout in
                guard isAdaptableType(workout.workoutType) else { return false }
                guard !workout.isCompleted else { return false }
                guard !excluding.contains(workout.id) else { return false }
                guard workout.scheduledDate >= today else { return false }
                if let after, workout.scheduledDate <= after { return false }
                return true
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    /// The soonest session the coach may adapt, or `nil` when the plan has none left.
    static func nextAdaptableWorkout(
        in plan: TrainingPlan?,
        after: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduledWorkout? {
        adaptableWorkouts(in: plan, after: after, now: now, calendar: calendar).first
    }

    /// Whether a workout type is one the coach may rewrite: a run, but not the race.
    static func isAdaptableType(_ type: WorkoutType) -> Bool {
        type.isRunType && type != .race
    }
}
