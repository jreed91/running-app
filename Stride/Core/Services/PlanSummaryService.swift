import Foundation

// MARK: - PlanStatus

/// Lifecycle state of a training plan, derived from `isActive` and its date range.
enum PlanStatus: Sendable, Equatable {
    /// The plan the user is currently following.
    case active
    /// An inactive plan whose scheduled end date has passed.
    case finished
    /// An inactive plan that was replaced or abandoned before its end date.
    case ended

    /// Presentation only — nothing compares or persists this, so unlike the display
    /// enums in `Enums.swift` it needs no canonical English twin (D8).
    var displayName: String {
        switch self {
        case .active:   return String(localized: "Active", comment: "Training plan status")
        case .finished: return String(localized: "Finished", comment: "Training plan status")
        case .ended:    return String(localized: "Ended", comment: "Training plan status")
        }
    }
}

// MARK: - PlanSummary

/// Aggregate statistics for a training plan, derived from its scheduled
/// workouts and the completed run/strength sessions linked to them.
struct PlanSummary: Sendable {
    /// Per-workout-type completion tally.
    struct TypeStat: Sendable, Identifiable {
        let type: WorkoutType
        let scheduled: Int
        let completed: Int

        var id: String { type.rawValue }
    }

    var status: PlanStatus
    /// Scheduled workouts that count toward adherence (rest days excluded).
    var scheduledCount: Int
    /// Scheduled non-rest workouts marked completed.
    var completedCount: Int
    var completedRunCount: Int
    var completedStrengthCount: Int
    /// Total distance across completed runs, in meters.
    var completedDistanceMeters: Double
    /// Sum of scheduled workout distance targets, in meters.
    var targetDistanceMeters: Double
    /// Total moving time across completed run and strength sessions, in seconds.
    var totalDurationSeconds: Double
    /// Distance-weighted average pace across completed runs (sec/km).
    /// Nil when no run distance was logged.
    var averagePaceSecondsPerKm: Double?
    /// Longest completed run, in meters. Zero when no runs were logged.
    var longestRunMeters: Double
    var weeksCompleted: Int
    var totalWeeks: Int
    /// Scheduled/completed counts per workout type, most-scheduled first.
    var typeBreakdown: [TypeStat]

    /// 0–1 fraction of scheduled (non-rest) workouts that were completed.
    var adherence: Double {
        guard scheduledCount > 0 else { return 0 }
        return Double(completedCount) / Double(scheduledCount)
    }
}

// MARK: - PlanSummaryService

/// Pure, stateless service that aggregates a ``TrainingPlan``'s scheduled and
/// completed workouts into a ``PlanSummary`` for plan-history views.
struct PlanSummaryService: Sendable {

    /// Aggregates the plan's scheduled workouts and linked completed sessions.
    static func summary(for plan: TrainingPlan, now: Date = Date()) -> PlanSummary {
        let weeks = plan.weeks ?? []
        let allWorkouts = weeks.flatMap { $0.workouts ?? [] }
        let scheduled = allWorkouts.filter { $0.workoutType != .rest }
        let completed = scheduled.filter(\.isCompleted)

        // Runs only: a cross-training day is completed through the same link by an
        // imported ride or swim (B8), whose distance and pace are not running ones.
        let linked = allWorkouts.compactMap(\.completedWorkout)
        let runs = linked.runsOnly
        let crossTrainingSessions = linked.filter(\.isCrossTraining)
        let strengthSessions = allWorkouts.compactMap(\.completedStrengthWorkout)

        let completedDistance = runs.reduce(0) { $0 + $1.distanceMeters }
        let runDuration = runs.reduce(0) { $0 + $1.durationSeconds }
        let strengthDuration = strengthSessions.reduce(0) { $0 + $1.durationSeconds }
        // Time is the one total a ride does belong in: it was training the plan asked for.
        let crossTrainingDuration = crossTrainingSessions.reduce(0) { $0 + $1.durationSeconds }

        // Distance-weighted pace: total run time over total run distance.
        let averagePace: Double? = completedDistance > 0 && runDuration > 0
            ? runDuration / completedDistance * 1_000
            : nil

        let byType = Dictionary(grouping: scheduled, by: \.workoutType)
        let typeBreakdown = byType
            .map { type, workouts in
                PlanSummary.TypeStat(
                    type: type,
                    scheduled: workouts.count,
                    completed: workouts.filter(\.isCompleted).count
                )
            }
            .sorted {
                $0.scheduled != $1.scheduled
                    ? $0.scheduled > $1.scheduled
                    : $0.type.rawValue < $1.type.rawValue
            }

        return PlanSummary(
            status: status(of: plan, now: now),
            scheduledCount: scheduled.count,
            completedCount: completed.count,
            completedRunCount: runs.count,
            completedStrengthCount: strengthSessions.count,
            completedDistanceMeters: completedDistance,
            targetDistanceMeters: scheduled.reduce(0) { $0 + ($1.targetDistanceMeters ?? 0) },
            totalDurationSeconds: runDuration + strengthDuration + crossTrainingDuration,
            averagePaceSecondsPerKm: averagePace,
            longestRunMeters: runs.map(\.distanceMeters).max() ?? 0,
            weeksCompleted: weeks.filter(\.isCompleted).count,
            totalWeeks: weeks.count,
            typeBreakdown: typeBreakdown
        )
    }

    /// Derives the plan's lifecycle state.
    static func status(of plan: TrainingPlan, now: Date = Date()) -> PlanStatus {
        if plan.isActive { return .active }
        return plan.endDate < now ? .finished : .ended
    }
}
