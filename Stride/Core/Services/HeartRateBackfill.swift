import Foundation

// MARK: - HeartRateBackfill

/// Picks which already-imported runs still need their heart-rate samples fetched.
///
/// Runs imported before HR samples were persisted carry none, and the Progress
/// time-in-zone chart only reads persisted samples — so it reported "No heart-rate zone
/// data in this period" until the runner happened to open each individual run, at which
/// point it partially filled in. That reads as a bug from the outside (N25).
///
/// The selection is deliberately bounded: each candidate costs one HealthKit sample
/// query, so a period holding hundreds of runs must not turn opening the Progress tab
/// into hundreds of queries.
enum HeartRateBackfill {

    /// Most runs one pass will fetch. Sized so a pass stays comfortably sub-second on
    /// device while still filling a typical month in one go.
    static let maximumRunsPerPass = 25

    /// Runs that could gain samples: no persisted samples, but a HealthKit workout to
    /// fetch them from. Newest first, so the runs a user is most likely looking at fill
    /// in before older ones, and capped at `limit`.
    ///
    /// `alreadyAttempted` holds ids from earlier passes in this session; a workout whose
    /// HealthKit source is gone returns nothing forever, and without this the same
    /// fruitless queries would rerun on every period change.
    static func runsNeedingSamples(
        in runs: [RunWorkout],
        alreadyAttempted: Set<String> = [],
        limit: Int = maximumRunsPerPass
    ) -> [RunWorkout] {
        guard limit > 0 else { return [] }
        return runs
            .filter { run in
                guard run.heartRateSamples.isEmpty else { return false }
                guard let id = run.healthKitWorkoutID else { return false }
                return !alreadyAttempted.contains(id)
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }
}
