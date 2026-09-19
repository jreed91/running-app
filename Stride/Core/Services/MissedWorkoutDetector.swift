import Foundation

// MARK: - MissedWorkoutInfo

struct MissedWorkoutInfo: Equatable, Sendable {
    /// Number of consecutive missed workouts in the trailing streak.
    let count: Int
    /// scheduledDate of the first missed workout, normalized to start-of-day.
    let firstMissedDate: Date
    /// Calendar days between firstMissedDate and today (how far behind schedule the plan is).
    let daysToShift: Int
}

// MARK: - MissedWorkoutDetector

struct MissedWorkoutDetector {

    static let minimumConsecutiveMissed = 2

    /// Defaults key holding when the dashboard's recovery card was last put away
    /// (dismissed or acted on), as a `timeIntervalSince1970`. The card shows at most once
    /// a week and reads this to decide.
    ///
    /// Shared rather than spelled out at each call site because the evening push
    /// (`TrainingNudgePolicy.missedWorkoutNudge`) has to honour the same dismissal as the
    /// card — two spellings of the key is how the Lock Screen ends up asking a question
    /// the runner already answered on the dashboard.
    static let promptFlaggedDateKey = "missedWorkoutPromptFlaggedDate"

    /// Returns non-nil when there are 2+ consecutive past non-rest workouts that were not completed.
    ///
    /// "Consecutive" is evaluated from the most-recent missed workout backwards: a completed
    /// non-rest workout anywhere in the streak resets it, so a gap from weeks ago that the user
    /// has since recovered from will not re-trigger the banner.
    static func detect(in plan: TrainingPlan, today: Date = .now) -> MissedWorkoutInfo? {
        let startOfToday = Calendar.current.startOfDay(for: today)

        // Flatten all workouts from the plan's weeks.
        let allWorkouts: [ScheduledWorkout] = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }

        // Keep only past non-rest/strength/crossTraining workouts, sorted ascending.
        let candidates: [ScheduledWorkout] = allWorkouts.filter { w in
            w.scheduledDate < startOfToday
                && w.workoutType != .rest
                && w.workoutType != .strength
                && w.workoutType != .crossTraining
        }
        let allPastNonRest: [ScheduledWorkout] = candidates.sorted { $0.scheduledDate < $1.scheduledDate }

        // Walk backward to find the trailing consecutive missed streak.
        // Stop at the first completed workout — any completed workout resets the streak.
        var streak: [ScheduledWorkout] = []
        for workout in allPastNonRest.reversed() {
            if workout.isCompleted {
                break
            }
            streak.append(workout)
        }

        guard streak.count >= Self.minimumConsecutiveMissed else { return nil }

        // streak is in reverse order; find earliest scheduled date.
        let earliest = streak.min(by: { $0.scheduledDate < $1.scheduledDate })!
        let firstMissedDate = Calendar.current.startOfDay(for: earliest.scheduledDate)
        let daysToShift = Calendar.current.dateComponents([.day], from: firstMissedDate, to: startOfToday).day ?? 0

        return MissedWorkoutInfo(
            count: streak.count,
            firstMissedDate: firstMissedDate,
            daysToShift: daysToShift
        )
    }
}
