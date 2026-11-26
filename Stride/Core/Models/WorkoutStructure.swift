import Foundation

// The shape of a structured session, in its own Foundation-only file so `StrideWatch`
// can compile it beside `GuidedWorkoutEngine` and step a runner through the same warm-up,
// reps and cool-down the phone does (Watch runs, PR 1). `ValueTypes.swift` imports
// CoreLocation and reaches into app-only types, so the watch cannot take that file whole.

// MARK: - WorkoutSegment

/// A single continuous segment of a run (warm-up, work repeat, recovery, cool-down).
struct WorkoutSegment: Codable, Hashable, Sendable {
    /// Target distance in meters. Nil when segment is time-based or open.
    var distanceMeters: Double?
    /// Target duration in seconds. Nil when segment is distance-based or open.
    var durationSeconds: Double?
    /// Target pace in seconds/km. Nil for open/recovery segments.
    var targetPaceSecondsPerKm: Double?
    /// Human-readable label, e.g. "Warm-up", "Cool-down", "Recovery jog".
    var label: String
}

// MARK: - WorkoutSet

/// One repeated block: N repetitions of a work segment followed by a recovery segment.
struct WorkoutSet: Codable, Hashable, Sendable {
    var repetitions: Int
    var workSegment: WorkoutSegment
    var recoverySegment: WorkoutSegment
    /// Human-readable label, e.g. "VO2max Intervals", "Tempo Block".
    var label: String

    /// Total recovery time across the whole set, in seconds.
    ///
    /// There are only `repetitions - 1` recovery jogs: the final repetition is
    /// followed by the cool-down, not another recovery, so a recovery is never
    /// counted after the last rep. Returns 0 when there is a single rep (or none)
    /// or when the recovery segment has no duration.
    var totalRecoverySeconds: Double {
        guard repetitions > 1, let recovery = recoverySegment.durationSeconds else { return 0 }
        return Double(repetitions - 1) * recovery
    }
}

// MARK: - WorkoutStructure

/// Full structured representation of a workout with warm-up, main sets, and cool-down.
/// Serialised to JSON and stored in ``ScheduledWorkout/structureData``.
struct WorkoutStructure: Codable, Hashable, Sendable {
    var warmup: WorkoutSegment
    var mainSets: [WorkoutSet]
    var cooldown: WorkoutSegment
    var totalEstimatedDistanceMeters: Double
    var totalEstimatedDurationSeconds: Double
}
