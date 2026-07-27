import Foundation

// MARK: - SplitBackfill

/// Decides whether an already-imported run can still gain the splits it was imported
/// without.
///
/// Imports have bucketed real splits since N9, but every run imported *before* that
/// carries none — and the run detail screen gates the split pace chart, the split HR and
/// elevation charts, and the splits table on `!splits.isEmpty`, so those runs show none
/// of it forever. `WorkoutAnalyticsService.intervalEffortPace` also falls back to the
/// session average for them, which is the misclassification H2.1 fixed.
///
/// This is the selection half of the same shape ``HeartRateBackfill`` uses for heart
/// rate: keep the "is it worth one HealthKit query?" rule pure and testable, and leave
/// the fetching to the caller.
enum SplitBackfill {

    /// Whether asking HealthKit for this run's distance series could produce splits.
    ///
    /// Three things have to hold, and all three save a pointless query:
    /// - the run has no splits already (a backfilled or app-recorded run is done);
    /// - it came from HealthKit, so there is a workout to fetch samples from — an
    ///   app-recorded run with no splits never had a distance series to bucket;
    /// - it covered at least one whole bucket, since `SplitBucketing` emits a split only
    ///   when a boundary is crossed and a 600 m shakeout can never cross one.
    static func needsSplits(_ run: RunWorkout, splitLengthMeters: Double) -> Bool {
        guard splitLengthMeters > 0 else { return false }
        guard run.splits.isEmpty else { return false }
        guard run.healthKitWorkoutID != nil else { return false }
        return run.distanceMeters >= splitLengthMeters
    }

    /// Whether the same query is worth making for the run's distance *series* (N34).
    ///
    /// A run imported before the series was persisted has splits and no readings behind
    /// them, so its split charts are stuck at whole-unit buckets — one marker for a one-mile
    /// run. The series is the same fetch the splits came from, so a run that needs either
    /// costs one query and gains both.
    ///
    /// No bucket-length floor here, unlike `needsSplits`: a run too short to cross a whole
    /// boundary is exactly the one whose charts the finer buckets rescue.
    static func needsDistanceSeries(_ run: RunWorkout) -> Bool {
        guard run.distanceSeries.isEmpty else { return false }
        guard run.healthKitWorkoutID != nil else { return false }
        return run.distanceMeters > 0
    }
}
