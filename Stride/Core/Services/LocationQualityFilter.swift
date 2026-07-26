import Foundation

// MARK: - LocationQualityFilter

/// Pure accept/reject decision for a single GPS fix on the live tracking path (N8).
///
/// `WorkoutTrackerService.processLocation` used to accept every fix Core Location
/// delivered: no check on `horizontalAccuracy` (negative means the reading is
/// invalid), no staleness check on `timestamp` (the manager hands over a cached
/// fix the moment updates start), and no sanity cap on the implied speed. Under
/// trees, between buildings, or in the seconds after location updates start
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
    /// while the cached fix Core Location replays when updates start is
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

    // MARK: - Signal quality (U5c)

    /// How good reception is right now, for the runner rather than for the log.
    ///
    /// The filter above already grades every fix and discards the bad ones, but that
    /// verdict never left this file: under tree cover or between buildings the HUD
    /// showed a plausible pace with no hint that the fixes behind it were being
    /// thrown away. This is the same accuracy reading, expressed as something a
    /// screen can display.
    enum SignalQuality: String, Sendable, CaseIterable {
        /// Fixes are precise enough to trust the pace between them.
        case strong
        /// Usable, but the live pace will wander.
        case fair
        /// At or past the accuracy ceiling — fixes are being discarded and distance
        /// is being under-counted.
        case weak

        /// Filled bars out of three, so the indicator reads without colour (U3d).
        var bars: Int {
            switch self {
            case .strong: return 3
            case .fair:   return 2
            case .weak:   return 1
            }
        }

        /// Spoken by VoiceOver, so it is localized (unlike `rawValue`, which is
        /// compared and logged).
        var localizedName: String {
            switch self {
            case .strong:
                return String(localized: "Strong", comment: "GPS signal quality")
            case .fair:
                return String(localized: "Fair", comment: "GPS signal quality")
            case .weak:
                return String(localized: "Weak", comment: "GPS signal quality")
            }
        }
    }

    /// Precise enough that the pace between two fixes is worth believing.
    static let strongHorizontalAccuracyMeters: Double = 8

    /// Grades reception from one fix's `horizontalAccuracy`, in metres.
    ///
    /// Deliberately graded from accuracy alone rather than from the rejection
    /// reasons: staleness and out-of-order fixes say something about the delivery
    /// path, not about reception, and a runner cannot act on either.
    static func signalQuality(forHorizontalAccuracy accuracy: Double) -> SignalQuality {
        guard accuracy >= 0, accuracy.isFinite else { return .weak }
        if accuracy <= strongHorizontalAccuracyMeters { return .strong }
        if accuracy <= maximumHorizontalAccuracyMeters { return .fair }
        return .weak
    }
}
