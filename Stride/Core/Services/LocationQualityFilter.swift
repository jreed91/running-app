import Foundation

// MARK: - LocationQualityFilter

/// Pure accept/reject decision for a single GPS fix on the live tracking path (N8).
///
/// `WorkoutTrackerService.processLocation` used to accept every fix Core Location
/// delivered: no check on `horizontalAccuracy` (negative means the reading is
/// invalid), no staleness check on `timestamp` (the manager hands over a cached
/// fix the moment updates start), and no sanity cap on the implied speed. Under
/// trees, between buildings, or in the seconds after `startUpdatingLocation()`
/// while the fix converges, that jitter was recorded as real distance and drawn
/// into the route. The auto-pause guard only suppressed *slow* movement, so a
/// 40 m accuracy spike read as fast movement and was kept.
///
/// The decision is expressed as a pure function over plain numbers so it can be
/// tested without Core Location.
enum LocationQualityFilter {

    /// The properties of one fix the filter needs, decoupled from `CLLocation`.
    struct Fix: Sendable, Equatable {
        /// Core Location's `horizontalAccuracy`, in metres. Negative means invalid.
        var horizontalAccuracy: Double
        /// How long ago the fix was taken, in seconds. Negative (clock skew) counts as fresh.
        var ageSeconds: TimeInterval
        /// Metres from the previously accepted fix. `nil` for the first fix of a segment.
        var distanceFromPreviousMeters: Double?
        /// Seconds between the previously accepted fix and this one. `nil` for the first fix.
        var secondsSincePreviousFix: TimeInterval?

        init(
            horizontalAccuracy: Double,
            ageSeconds: TimeInterval,
            distanceFromPreviousMeters: Double? = nil,
            secondsSincePreviousFix: TimeInterval? = nil
        ) {
            self.horizontalAccuracy = horizontalAccuracy
            self.ageSeconds = ageSeconds
            self.distanceFromPreviousMeters = distanceFromPreviousMeters
            self.secondsSincePreviousFix = secondsSincePreviousFix
        }
    }

    /// Why a fix was discarded. Recorded for diagnostics; never surfaced to the runner.
    enum Rejection: String, Sendable, CaseIterable {
        /// Core Location reports the horizontal reading as unusable.
        case invalidAccuracy
        /// The reading is real but too imprecise to attribute distance to.
        case poorAccuracy
        /// A cached or long-delayed fix, typically the first one after updates start.
        case stale
        /// The fix predates the last accepted one, so the delta would run time backwards.
        case outOfOrder
        /// The jump from the previous fix implies a speed no runner reaches.
        case impossibleSpeed
    }

    /// Fixes less precise than this contribute jitter rather than distance.
    /// Generous for `kCLLocationAccuracyBestForNavigation`, which settles well inside it.
    static let maximumHorizontalAccuracyMeters: Double = 25

    /// Fixes older than this are cached or badly delayed. Deliberately forgiving —
    /// a live fix that took a moment to reach the main actor must never be dropped,
    /// while the cached fix Core Location replays on `startUpdatingLocation()` is
    /// typically minutes old.
    static let maximumFixAgeSeconds: TimeInterval = 15

    /// ~45 km/h. Above the world-record sprint speed, so any delta implying more is
    /// a GPS jump, not running.
    static let maximumPlausibleSpeedMetersPerSecond: Double = 12.5

    /// The reason this fix should be discarded, or `nil` if it should be used.
    static func rejection(for fix: Fix) -> Rejection? {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy.isFinite else { return .invalidAccuracy }
        guard fix.horizontalAccuracy <= maximumHorizontalAccuracyMeters else { return .poorAccuracy }
        guard fix.ageSeconds <= maximumFixAgeSeconds else { return .stale }

        if let interval = fix.secondsSincePreviousFix {
            guard interval >= 0 else { return .outOfOrder }
            if let distance = fix.distanceFromPreviousMeters, distance > 0 {
                // A jump with no elapsed time between fixes is infinitely fast.
                guard interval > 0 else { return .impossibleSpeed }
                guard distance / interval <= maximumPlausibleSpeedMetersPerSecond else {
                    return .impossibleSpeed
                }
            }
        }
        return nil
    }

    /// Whether the fix is good enough to append to the route and accumulate distance from.
    static func accepts(_ fix: Fix) -> Bool { rejection(for: fix) == nil }
}
