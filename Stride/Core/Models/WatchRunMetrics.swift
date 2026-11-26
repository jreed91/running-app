import Foundation

// MARK: - WatchRunMetrics

/// What the Watch's live run screen shows, worked out from the raw numbers HealthKit's
/// live builder hands the recorder (Watch runs, PR 2).
///
/// Compiled into the app and `StrideWatch`, Foundation only, so the formatting and the
/// pace and zone math are unit-tested in `StrideTests` rather than only on a wrist.
struct WatchRunMetrics: Equatable, Sendable {
    /// Active time: paused time is not counted.
    var elapsedSeconds: TimeInterval
    var distanceMeters: Double
    /// The Watch's latest running speed, `nil` before the first reading or while standing.
    var currentSpeedMetersPerSecond: Double?
    var heartRateBPM: Double?

    static let zero = WatchRunMetrics(elapsedSeconds: 0, distanceMeters: 0)

    init(
        elapsedSeconds: TimeInterval,
        distanceMeters: Double,
        currentSpeedMetersPerSecond: Double? = nil,
        heartRateBPM: Double? = nil
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.distanceMeters = distanceMeters
        self.currentSpeedMetersPerSecond = currentSpeedMetersPerSecond
        self.heartRateBPM = heartRateBPM
    }

    // MARK: Pace

    /// Below this a runner is standing or walking to a stop; pace would read as hours.
    static let slowestPaceSpeed: Double = 0.5

    /// Seconds per kilometre from the current speed, or `nil` when there is none to show.
    var currentPaceSecondsPerKm: Double? {
        guard let speed = currentSpeedMetersPerSecond, speed >= Self.slowestPaceSpeed else { return nil }
        return 1_000 / speed
    }

    /// Seconds per kilometre over the whole run so far, or `nil` before the first 50 m.
    var averagePaceSecondsPerKm: Double? {
        guard distanceMeters >= 50, elapsedSeconds > 0 else { return nil }
        return elapsedSeconds / (distanceMeters / 1_000)
    }

    // MARK: Zone

    /// The heart-rate zone, when there is both a reading and a max heart rate.
    func zone(maxHeartRateBPM: Int?) -> HRZone? {
        guard let bpm = heartRateBPM, bpm > 0, let max = maxHeartRateBPM, max > 0 else { return nil }
        return HeartRateZoneService.zone(forBPM: bpm, maxHR: Double(max))
    }

    // MARK: Text

    /// "4:05" under an hour, "1:02:09" from an hour on.
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "5.23" kilometres or miles, two decimals, no unit (the screen labels it).
    static func distanceText(_ meters: Double, metric: Bool) -> String {
        String(format: "%.2f", max(0, meters) / (metric ? 1_000 : 1_609.344))
    }

    /// "4:58" per kilometre or mile, or "--:--" when there is no pace.
    static func paceText(secondsPerKm: Double?, metric: Bool) -> String {
        guard let secondsPerKm, secondsPerKm.isFinite, secondsPerKm > 0 else { return "--:--" }
        let perUnit = metric ? secondsPerKm : secondsPerKm * 1.609344
        let total = Int(perUnit.rounded())
        guard total < 60 * 60 else { return "--:--" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func distanceUnit(metric: Bool) -> String { metric ? "km" : "mi" }
    static func paceUnit(metric: Bool) -> String { metric ? "/km" : "/mi" }
}

// MARK: - WatchRunMetadata

/// Keys Stride's Watch app writes into the saved `HKWorkout`'s metadata, so the phone can
/// tell its own Watch runs apart and link one to the exact plan session
/// (`HealthKitRepository.watchSessionID(from:)`, `WorkoutSyncService.linkToScheduledWorkouts`).
enum WatchRunMetadata {
    /// The `ScheduledWorkout` id the run was started for, as a UUID string. Absent on a
    /// free run.
    static let sessionIDKey = "com.running.stride.sessionID"
}
