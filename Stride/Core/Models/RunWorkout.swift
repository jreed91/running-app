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
    /// Mean cadence over the run, in steps per minute.
    ///
    /// The pedometer has reported cadence on every run since N20, but only to the live
    /// HUD — it was discarded at finish, so the coach could never say anything about form
    /// and no screen could show it after the fact (A5). Optional so the CloudKit schema
    /// stays additive and so a run recorded without a pedometer reading stays honestly
    /// blank rather than claiming zero.
    var averageCadenceStepsPerMinute: Double?
    /// Raw-backed storage for `workoutType` to keep CloudKit fields primitive.
    var workoutTypeRaw: String = WorkoutType.easy.rawValue
    /// Raw-backed storage for `workoutLocation` to keep CloudKit fields primitive.
    var workoutLocationRaw: String = WorkoutLocation.outdoor.rawValue
    /// Distance unit the `splits` were bucketed in at record time. Runs recorded before
    /// unit-aware bucketing (and every legacy CloudKit record) default to `metric`, so
    /// their kilometre buckets keep reading honestly as "km" (A1).
    var splitUnitRaw: String = UnitPreference.metric.rawValue
    /// Absorbs the old CloudKit `workoutType` field so migration can recover it.
    @Attribute(originalName: "workoutType")
    var workoutTypeLegacy: String? = nil
    /// Absorbs the old CloudKit `workoutLocation` field so migration can recover it.
    @Attribute(originalName: "workoutLocation")
    var workoutLocationLegacy: String? = nil
    var notes: String?

    /// HealthKit workout UUID string, set after syncing.
    var healthKitWorkoutID: String?

    /// JSON-encoded `[Split]`.
    var splitsData: Data?

    /// JSON-encoded `[Lap]` — the laps the runner marked by hand during the run (A2).
    /// `nil` for the runs that were never lapped, which is most of them.
    var lapsData: Data?

    /// JSON-encoded `[Double]` of raw heart-rate bpm samples captured during the run
    /// (app-recorded) or fetched from HealthKit. Backs the time-in-zone breakdown (A6).
    var heartRateSamplesData: Data?

    /// JSON-encoded `[Coordinate]`.
    var routeData: Data?

    /// JSON-encoded `[SplitBucketing.DistancePoint]` — the run's cumulative distance
    /// readings, with altitude where the source had it.
    ///
    /// `splits` is closed on whole kilometre/mile boundaries, so a one-mile run has exactly
    /// one of them and its pace and heart-rate charts drew a single marker (N34). The series
    /// is the same data those splits were bucketed from, kept so the charts can re-bucket a
    /// short run at a finer resolution. Optional, and `nil` for every run recorded or
    /// imported before this: those still chart their stored splits.
    var distanceSeriesData: Data?

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

    /// Raw-backed storage for the runner's thumbs-up/down on the cached insight (N22).
    /// Optional so the CloudKit schema stays additive for existing records.
    var aiCoachReactionRaw: String?

    // MARK: Computed helpers (not persisted)

    var splits: [Split] {
        get { splitsData?.decode([Split].self) ?? [] }
        set { splitsData = .encoded(newValue, keeping: splitsData) }
    }

    /// The laps the runner marked during this run, in order. Empty for an unlapped run.
    var laps: [Lap] {
        get { lapsData?.decode([Lap].self) ?? [] }
        set { lapsData = newValue.isEmpty ? nil : .encoded(newValue, keeping: lapsData) }
    }

    var routeCoordinates: [Coordinate] {
        get { routeData?.decode([Coordinate].self) ?? [] }
        set { routeData = .encoded(newValue, keeping: routeData) }
    }

    /// The run's cumulative distance readings, empty when it was recorded before the series
    /// was persisted. `SplitChartSeries` re-buckets these for the split charts (N34).
    var distanceSeries: [SplitBucketing.DistancePoint] {
        get { distanceSeriesData?.decode([SplitBucketing.DistancePoint].self) ?? [] }
        set { distanceSeriesData = newValue.isEmpty ? nil : .encoded(newValue, keeping: distanceSeriesData) }
    }

    /// Raw heart-rate bpm samples for this run (empty if none captured/available).
    var heartRateSamples: [Double] {
        get { heartRateSamplesData?.decode([Double].self) ?? [] }
        set { heartRateSamplesData = newValue.isEmpty ? nil : .encoded(newValue, keeping: heartRateSamplesData) }
    }

    var weather: WorkoutWeather? {
        get { weatherData?.decode(WorkoutWeather.self) }
        set { weatherData = newValue.flatMap { .encoded($0, keeping: weatherData) } }
    }

    var cachedAIInsight: AICoachInsight? {
        get { cachedAIInsightData?.decode(AICoachInsight.self) }
        set { cachedAIInsightData = newValue.flatMap { .encoded($0, keeping: cachedAIInsightData) } }
    }

    /// The runner's rating of this run's coach insight, if they gave one (N22).
    var aiCoachReaction: AICoachReaction? {
        get { aiCoachReactionRaw.flatMap(AICoachReaction.init(rawValue:)) }
        set { aiCoachReactionRaw = newValue?.rawValue }
    }

    var workoutType: WorkoutType {
        get { WorkoutType(rawValue: workoutTypeRaw) ?? .easy }
        set { workoutTypeRaw = newValue.rawValue }
    }

    var workoutLocation: WorkoutLocation {
        get { WorkoutLocation(rawValue: workoutLocationRaw) ?? .outdoor }
        set { workoutLocationRaw = newValue.rawValue }
    }

    /// The distance unit each entry in `splits` represents (one bucket per km or per mile).
    var splitUnit: UnitPreference {
        get { UnitPreference(rawValue: splitUnitRaw) ?? .metric }
        set { splitUnitRaw = newValue.rawValue }
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
