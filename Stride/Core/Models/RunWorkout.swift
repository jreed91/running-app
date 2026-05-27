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
    /// Raw-backed storage for `workoutType` to keep CloudKit fields primitive.
    var workoutTypeRaw: String = WorkoutType.easy.rawValue
    /// Raw-backed storage for `workoutLocation` to keep CloudKit fields primitive.
    var workoutLocationRaw: String = WorkoutLocation.outdoor.rawValue
    /// Absorbs the old CloudKit `workoutType` field so migration can recover it.
    @Attribute(originalName: "workoutType")
    var workoutTypeLegacy: String? = nil
    /// Absorbs the old CloudKit `workoutLocation` field so migration can recover it.
    @Attribute(originalName: "workoutLocation")
    var workoutLocationLegacy: String? = nil
    var notes: String?

    /// HealthKit workout UUID string, set after syncing.
    var healthKitWorkoutID: String?

    /// Strava upload identifier, set once an upload has been accepted by Strava.
    /// Its presence marks the run as already pushed so auto-sync never uploads it twice.
    var stravaUploadID: Int?

    /// Strava activity identifier, populated once Strava finishes processing the upload
    /// (or recovered from a duplicate-upload response).
    var stravaActivityID: Int?

    /// Timestamp of the most recent successful Strava upload attempt.
    var stravaUploadedAt: Date?

    /// JSON-encoded `[Split]`.
    var splitsData: Data?

    /// JSON-encoded `[Coordinate]`.
    var routeData: Data?

    /// Back-reference to the ``ScheduledWorkout`` this run fulfilled, if any.
    /// The inverse is declared on ``ScheduledWorkout/completedWorkout``; SwiftData infers it here.
    var scheduledWorkout: ScheduledWorkout?

    /// Primitive backup of the linked scheduled workout's ID. CloudKit syncs scalar UUIDs
    /// more reliably than relationship references when records arrive out of order during a
    /// restore. Used by ``ProfileRestoreDeduplicator/repairRelationships(in:)`` to re-stitch
    /// the relationship after reinstall.
    var linkedScheduledWorkoutID: UUID?

    /// JSON-encoded ``WorkoutWeather``.
    var weatherData: Data?

    /// JSON-encoded ``AICoachInsight`` cached after first load.
    var cachedAIInsightData: Data?

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

    var cachedAIInsight: AICoachInsight? {
        get { cachedAIInsightData?.decode(AICoachInsight.self) }
        set { cachedAIInsightData = newValue.flatMap { .encoded($0) } }
    }

    var workoutType: WorkoutType {
        get { WorkoutType(rawValue: workoutTypeRaw) ?? .easy }
        set { workoutTypeRaw = newValue.rawValue }
    }

    /// True once the run has been pushed to Strava (or is in-flight), so it is not re-uploaded.
    var isUploadedToStrava: Bool { stravaUploadID != nil }

    var workoutLocation: WorkoutLocation {
        get { WorkoutLocation(rawValue: workoutLocationRaw) ?? .outdoor }
        set { workoutLocationRaw = newValue.rawValue }
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
