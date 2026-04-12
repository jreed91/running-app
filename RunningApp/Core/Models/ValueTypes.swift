import Foundation
import CoreLocation

// MARK: - Coordinate

/// Sendable, Codable wrapper around CLLocationCoordinate2D for storage.
struct Coordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Split

/// Per-kilometre split data captured during a run.
struct Split: Codable, Hashable, Sendable {
    var kilometer: Int
    var paceSecondsPerKm: Double
    var heartRate: Double?
    var elevationGainMeters: Double
    var cumulativeDistanceMeters: Double
}

// MARK: - WorkoutInterval

/// A single repeat within an interval training session.
struct WorkoutInterval: Codable, Hashable, Sendable {
    var repetitions: Int
    var distanceMeters: Double?
    var durationSeconds: Double?
    var targetPaceSecondsPerKm: Double?
    var recoverySeconds: Double
    var recoveryType: RecoveryType
}

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
