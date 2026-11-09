import Foundation

// MARK: - StrengthPlanRefresher

/// Rewrites the exercises on the strength sessions still ahead in a plan, after the runner
/// changed their equipment or focus in Settings.
///
/// Only sessions from today on that are not done: a finished session is history, and its
/// logged sets point into the plan it was run from. Each session gets what the plan
/// generator would have given it for its week's phase, and on a pregnancy plan the same
/// trimester adaptation the pregnancy generator applies, so a Settings change can never
/// put a supine exercise back into the third trimester.
///
/// It changes exercises, never days: a plan with no strength days gets none from here
/// (a rebuild adds them), and the sessions keep their dates.
@MainActor
enum StrengthPlanRefresher {

    /// Rewrites the sessions and returns how many changed.
    @discardableResult
    static func refresh(
        _ plan: TrainingPlan,
        equipment: [StrengthEquipment],
        focus: StrengthFocus,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let today = calendar.startOfDay(for: now)
        // A pregnancy plan keeps bodyweight sessions when nothing is chosen, as its
        // generator does; elsewhere Settings never saves an empty choice.
        let effective = equipment.isEmpty ? [StrengthEquipment.bodyweight] : equipment
        var changed = 0

        for week in plan.weeks ?? [] {
            for workout in week.workouts ?? [] {
                guard workout.workoutType == .strength,
                      !workout.isCompleted,
                      calendar.startOfDay(for: workout.scheduledDate) >= today
                else { continue }

                var next = StrengthLibrary.plan(for: effective, focus: focus, phase: week.phase)
                if plan.isPregnancyPlan, let dueDate = plan.dueDate {
                    let gestationalWeek = GestationalAge.on(week.startDate, dueDate: dueDate, calendar: calendar).weeks
                    next = PregnancyStrengthAdapter.adapt(next, atGestationalWeek: gestationalWeek)
                }
                guard !next.exercises.isEmpty, next != workout.strengthPlan else { continue }

                workout.strengthPlan = next
                if plan.planKind == .standard {
                    // The note the standard generator writes, so the day reads the new focus.
                    workout.notes = "\(focus.displayName) strength — \(next.estimatedDurationMinutes) min"
                }
                changed += 1
            }
        }
        return changed
    }
}
