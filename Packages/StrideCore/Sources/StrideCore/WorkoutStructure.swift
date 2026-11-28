import Foundation

// The shape of a structured session, in its own Foundation-only file so `StrideWatch`
// can compile it beside `GuidedWorkoutEngine` and step a runner through the same warm-up,
// reps and cool-down the phone does (Watch runs, PR 1). `ValueTypes.swift` imports
// CoreLocation and reaches into app-only types, so the watch cannot take that file whole.

// MARK: - WorkoutSegment

/// A single continuous segment of a run (warm-up, work repeat, recovery, cool-down).
public struct WorkoutSegment: Codable, Hashable, Sendable {
    /// Target distance in meters. Nil when segment is time-based or open.
    public var distanceMeters: Double?
    /// Target duration in seconds. Nil when segment is distance-based or open.
    public var durationSeconds: Double?
    /// Target pace in seconds/km. Nil for open/recovery segments.
    public var targetPaceSecondsPerKm: Double?
    /// Human-readable label, e.g. "Warm-up", "Cool-down", "Recovery jog".
    public var label: String

    /// No distance, no time and no name: a warm-up or cool-down the runner left out.
    ///
    /// Such a bookend is skipped when the session is run (``GuidedWorkoutState/flatten(_:)``)
    /// and when it is sent to the Workout app, rather than becoming an open "Warm-up" step
    /// that waits for a tap on Next before the first rep. A *named* open segment is kept:
    /// that is a step the session means to be run until the runner moves on.
    public var isEmpty: Bool {
        (distanceMeters ?? 0) <= 0 && (durationSeconds ?? 0) <= 0
            && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        distanceMeters: Double? = nil,
        durationSeconds: Double? = nil,
        targetPaceSecondsPerKm: Double? = nil,
        label: String
    ) {
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.targetPaceSecondsPerKm = targetPaceSecondsPerKm
        self.label = label
    }
}

// MARK: - WorkoutSet

/// One repeated block: N repetitions of a work segment followed by a recovery segment.
public struct WorkoutSet: Codable, Hashable, Sendable {
    public var repetitions: Int
    public var workSegment: WorkoutSegment
    public var recoverySegment: WorkoutSegment
    /// Human-readable label, e.g. "VO2max Intervals", "Tempo Block".
    public var label: String

    /// Total recovery time across the whole set, in seconds.
    ///
    /// There are only `repetitions - 1` recovery jogs: the final repetition is
    /// followed by the cool-down, not another recovery, so a recovery is never
    /// counted after the last rep. Returns 0 when there is a single rep (or none)
    /// or when the recovery segment has no duration.
    public var totalRecoverySeconds: Double {
        guard repetitions > 1, let recovery = recoverySegment.durationSeconds else { return 0 }
        return Double(repetitions - 1) * recovery
    }

    public init(
        repetitions: Int,
        workSegment: WorkoutSegment,
        recoverySegment: WorkoutSegment,
        label: String
    ) {
        self.repetitions = repetitions
        self.workSegment = workSegment
        self.recoverySegment = recoverySegment
        self.label = label
    }
}

// MARK: - WorkoutStructure

/// Full structured representation of a workout with warm-up, main sets, and cool-down.
/// Serialised to JSON and stored in ``ScheduledWorkout/structureData``.
public struct WorkoutStructure: Codable, Hashable, Sendable {
    public var warmup: WorkoutSegment
    public var mainSets: [WorkoutSet]
    public var cooldown: WorkoutSegment
    public var totalEstimatedDistanceMeters: Double
    public var totalEstimatedDurationSeconds: Double

    public init(
        warmup: WorkoutSegment,
        mainSets: [WorkoutSet],
        cooldown: WorkoutSegment,
        totalEstimatedDistanceMeters: Double,
        totalEstimatedDurationSeconds: Double
    ) {
        self.warmup = warmup
        self.mainSets = mainSets
        self.cooldown = cooldown
        self.totalEstimatedDistanceMeters = totalEstimatedDistanceMeters
        self.totalEstimatedDurationSeconds = totalEstimatedDurationSeconds
    }
}
