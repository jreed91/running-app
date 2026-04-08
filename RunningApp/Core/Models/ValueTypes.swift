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
