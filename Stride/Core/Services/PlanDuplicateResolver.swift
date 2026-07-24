import Foundation

// MARK: - PlanDuplicateResolver

/// Decides which of a plan's scheduled workouts are genuine same-day duplicates.
///
/// Pure and free of SwiftData mutation so the rule — the part that decides what
/// gets *deleted* — is unit-testable; callers perform the deletion. Extracted from
/// `PlanTabView`, where it ran inline during Smart Adapt (per AGENTS.md: business
/// logic belongs in services, not views).
///
/// The rule: a workout is a duplicate only of another workout **on the same day and
/// of the same session kind**. Grouping by day alone treated a runner's easy run and
/// their gym session as duplicates of each other and deleted the lower-priority one
/// — in practice the strength session. Plans reach that state through ordinary use,
/// because "pick up where I left off" shifts runs forward onto strength days (N6).
enum PlanDuplicateResolver {

    /// Ranking used to choose the survivor within a group of same-day, same-kind
    /// workouts. Completed work always wins; otherwise the more specific session does.
    static func priority(_ workout: ScheduledWorkout) -> Int {
        if workout.isCompleted { return 0 }
        switch workout.workoutType {
        case .race: return 1
        case .longRun: return 2
        case .tempo, .interval: return 3
        case .easy: return 4
        case .strength: return 5
        case .crossTraining: return 6
        case .rest: return 7
        }
    }

    /// Identity a duplicate is judged against: same day *and* same kind of session.
    private struct GroupKey: Hashable {
        let day: Date
        let kind: WorkoutType.SessionKind
    }

    /// The workouts that should be removed from `workouts` so that at most one
    /// session of each kind remains on any given day. Returns them in no particular
    /// order; the survivor of each group is never included.
    static func redundantWorkouts(
        in workouts: [ScheduledWorkout],
        calendar: Calendar = .current
    ) -> [ScheduledWorkout] {
        let grouped = Dictionary(grouping: workouts) { workout in
            GroupKey(
                day: calendar.startOfDay(for: workout.scheduledDate),
                kind: workout.workoutType.sessionKind
            )
        }

        return grouped.values.flatMap { group -> [ScheduledWorkout] in
            guard group.count > 1 else { return [] }
            guard let survivor = group.min(by: { priority($0) < priority($1) }) else { return [] }
            return group.filter { $0.id != survivor.id }
        }
    }
}
