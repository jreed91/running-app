import Foundation

/// Climb from a noisy altitude stream, counted through a dead band.
///
/// Elevation gain used to be the sum of every positive fix-to-fix altitude change. GPS
/// altitude wobbles by a metre or two between fixes even on flat ground, and summing
/// only the ups of that wobble turns it into climb: a flat 10 km could report tens of
/// metres (P3). A reading now counts only once it is ``thresholdMeters`` above the last
/// confirmed level, and a drop of the same size resets the level, so jitter inside the
/// band adds nothing while a real hill still counts in full, less at most one band at
/// its top.
///
/// The live tracker and `SplitBucketing.splits(from:)` both use this, so a run's total,
/// its live splits and its re-bucketed chart splits measure climb the same way.
public struct ElevationGainAccumulator: Sendable, Equatable {

    /// Three metres: iPhone altitude is barometer-assisted, so its jitter sits inside this,
    /// while a short real rise still clears it.
    public static let defaultThresholdMeters: Double = 3

    /// Altitudes reported with a vertical accuracy worse than this are left out of the
    /// climb, and out of the stored series.
    public static let maximumVerticalAccuracyMeters: Double = 15

    public let thresholdMeters: Double
    public private(set) var confirmedAltitude: Double?

    public init(thresholdMeters: Double = defaultThresholdMeters) {
        self.thresholdMeters = thresholdMeters
    }

    /// Feeds one reading and returns the climb it confirms, which is zero for most
    /// readings.
    public mutating func add(_ altitude: Double) -> Double {
        guard altitude.isFinite else { return 0 }
        guard let confirmed = confirmedAltitude else {
            confirmedAltitude = altitude
            return 0
        }
        let change = altitude - confirmed
        if change >= thresholdMeters {
            confirmedAltitude = altitude
            return change
        }
        if change <= -thresholdMeters {
            confirmedAltitude = altitude
        }
        return 0
    }

    /// The altitude of a fix if it is worth using: Core Location reports a negative
    /// vertical accuracy when the altitude is invalid.
    public static func usableAltitude(_ altitude: Double, verticalAccuracy: Double) -> Double? {
        guard altitude.isFinite,
              verticalAccuracy >= 0,
              verticalAccuracy <= maximumVerticalAccuracyMeters
        else { return nil }
        return altitude
    }
}
