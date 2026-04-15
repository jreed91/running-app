import Foundation
import SwiftData

@Model
final class RunWorkout {
    var id: UUID
    var date: Date
    var distanceMeters: Double
    var durationSeconds: Double
    var averagePaceSecondsPerKm: Double
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var elevationGainMeters: Double?
    var workoutType: WorkoutType
    var notes: String?

    /// HealthKit workout UUID string, set after syncing.
    var healthKitWorkoutID: String?

    /// JSON-encoded `[Split]`.
    var splitsData: Data?

    /// JSON-encoded `[Coordinate]`.
    var routeData: Data?

    // MARK: Computed helpers (not persisted)

    var splits: [Split] {
        get {
            guard let data = splitsData else { return [] }
            return (try? JSONDecoder().decode([Split].self, from: data)) ?? []
        }
        set {
            splitsData = try? JSONEncoder().encode(newValue)
        }
    }

    var routeCoordinates: [Coordinate] {
        get {
            guard let data = routeData else { return [] }
            return (try? JSONDecoder().decode([Coordinate].self, from: data)) ?? []
        }
        set {
            routeData = try? JSONEncoder().encode(newValue)
        }
    }

    init(
        date: Date = Date(),
        distanceMeters: Double,
        durationSeconds: Double,
        workoutType: WorkoutType = .easy
    ) {
        self.id = UUID()
        self.date = date
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.averagePaceSecondsPerKm = distanceMeters > 0
            ? (durationSeconds / distanceMeters * 1_000)
            : 0
        self.workoutType = workoutType
    }
}
