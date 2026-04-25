import Foundation
import SwiftData

@Model
final class RunWorkout {
    #Index<RunWorkout>([\.id], [\.date])

    var id: UUID = UUID()
    var date: Date = Date()
    var distanceMeters: Double = 0
    var durationSeconds: Double = 0
    var averagePaceSecondsPerKm: Double = 0
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var elevationGainMeters: Double?
    var workoutType: WorkoutType = WorkoutType.easy
    var workoutLocation: WorkoutLocation = WorkoutLocation.outdoor
    var notes: String?

    /// HealthKit workout UUID string, set after syncing.
    var healthKitWorkoutID: String?

    /// JSON-encoded `[Split]`.
    var splitsData: Data?

    /// JSON-encoded `[Coordinate]`.
    var routeData: Data?

    /// Back-reference to the ``ScheduledWorkout`` this run fulfilled, if any.
    /// Required by CloudKit (every relationship must have an inverse).
    var scheduledWorkout: ScheduledWorkout?

    /// JSON-encoded ``WorkoutWeather``.
    var weatherData: Data?

    // MARK: Computed helpers (not persisted)

    var splits: [Split] {
        get { splitsData?.decode([Split].self) ?? [] }
        set { splitsData = .encoded(newValue) }
    }

    var routeCoordinates: [Coordinate] {
        get { routeData?.decode([Coordinate].self) ?? [] }
        set { routeData = .encoded(newValue) }
    }

    var weather: WorkoutWeather? {
        get { weatherData?.decode(WorkoutWeather.self) }
        set { weatherData = newValue.flatMap { .encoded($0) } }
    }

    init(
        date: Date = Date(),
        distanceMeters: Double,
        durationSeconds: Double,
        workoutType: WorkoutType = .easy,
        workoutLocation: WorkoutLocation = .outdoor
    ) {
        self.id = UUID()
        self.date = date
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.averagePaceSecondsPerKm = distanceMeters > 0
            ? (durationSeconds / distanceMeters * 1_000)
            : 0
        self.workoutType = workoutType
        self.workoutLocation = workoutLocation
    }
}
