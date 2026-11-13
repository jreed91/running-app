import Foundation

// MARK: - RouteBackfill

/// Picks which already-imported runs still need their GPS route fetched from HealthKit.
///
/// A run recorded in Apple's Workout app on the Watch reaches the phone in two parts:
/// the workout first, its route (`HKWorkoutRoute`) seconds to minutes later, once the
/// Watch finishes syncing the GPS series. The observer fires on the workout, so the sync
/// pass often reads the route before it exists, imports the run without one, and — since
/// the run's HealthKit id is then "existing" — never looks again. The map says "No route
/// data" forever, and the run gets no weather either, since weather is keyed off the
/// route's first point. A route query that fails outright (the phone locked, so Health
/// data is protected) lands in the same place.
///
/// This is the same selection shape ``HeartRateBackfill`` uses: keep "is it worth one
/// HealthKit query?" pure and testable, and leave the fetching to the caller.
enum RouteBackfill {

    /// How far back the sync pass looks for a run whose route arrived late. A route is
    /// normally on the phone within minutes of the workout, so a few days covers a Watch
    /// that stayed away from its phone overnight without re-querying old treadmill runs
    /// from apps that never mark them indoor. The run screen covers anything older.
    static let syncLookbackDays = 3

    /// Most runs one sync pass will query. Each costs two HealthKit queries.
    static let maximumRunsPerPass = 5

    /// Whether asking HealthKit for this run's route could give it one: an outdoor run
    /// with no route yet, and a HealthKit workout to read the route from. Indoor runs
    /// have no route to find; an app-recorded run without an id has no workout to ask.
    static func needsRoute(_ run: RunWorkout) -> Bool {
        guard run.workoutLocation == .outdoor else { return false }
        guard run.healthKitWorkoutID != nil else { return false }
        return run.routeCoordinates.isEmpty
    }

    /// The runs a sync pass should query, newest first and capped at `limit`.
    ///
    /// `alreadyAttempted` holds HealthKit ids queried earlier in this session: a workout
    /// that genuinely has no route (a run with location off, a treadmill run another app
    /// did not mark indoor) answers "none" every time, and the observer fires often.
    static func runsNeedingRoute(
        in runs: [RunWorkout],
        alreadyAttempted: Set<String> = [],
        limit: Int = maximumRunsPerPass
    ) -> [RunWorkout] {
        guard limit > 0 else { return [] }
        return runs
            .filter { run in
                guard needsRoute(run), let id = run.healthKitWorkoutID else { return false }
                return !alreadyAttempted.contains(id)
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }
}
