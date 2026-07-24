import Foundation

/// Pure split-boundary math shared by the outdoor (GPS) and indoor (pedometer) tracking
/// paths so both bucket splits identically. Splits are bucketed by the user's distance unit
/// at record time — one bucket per kilometre or per mile — so imperial runners get genuine
/// per-mile splits rather than kilometre buckets merely relabelled "mi" (A1).
enum SplitBucketing {

    /// The count of whole split buckets completed at a given cumulative distance.
    /// e.g. at 2 400 m with a 1 000 m bucket this is `2`; with a 1 609.344 m (mile) bucket, `1`.
    static func bucketIndex(distanceMeters: Double, splitLengthMeters: Double) -> Int {
        guard splitLengthMeters > 0, distanceMeters > 0 else { return 0 }
        return Int(distanceMeters / splitLengthMeters)
    }

    /// Whether advancing from `previousMeters` to `currentMeters` completes at least one new
    /// bucket, i.e. a split should be recorded for `currentMeters`.
    static func crossedBoundary(
        previousMeters: Double,
        currentMeters: Double,
        splitLengthMeters: Double
    ) -> Bool {
        bucketIndex(distanceMeters: currentMeters, splitLengthMeters: splitLengthMeters)
            > bucketIndex(distanceMeters: previousMeters, splitLengthMeters: splitLengthMeters)
    }

    // MARK: - Split pace (N7)

    /// The average pace across one split bucket — Δtime ÷ Δdistance — in seconds per
    /// kilometre, regardless of the bucket's own unit.
    ///
    /// This is what the split chart, the splits table, and the share card's "fastest
    /// split" callout all claim to show. The tracker used to store whatever
    /// `currentPaceSecondsPerKm` happened to hold at the instant a boundary was
    /// crossed: outdoors the *instantaneous* speed of a single GPS fix, indoors the
    /// *cumulative session average* (so every indoor split reported the same number
    /// and a negative-split run rendered flat).
    ///
    /// Returns `nil` for a bucket with no measurable distance or non-positive
    /// elapsed time, so callers fall back rather than store an infinite pace.
    static func splitPaceSecondsPerKm(deltaSeconds: Double, deltaMeters: Double) -> Double? {
        guard deltaSeconds > 0, deltaMeters > 0,
              deltaSeconds.isFinite, deltaMeters.isFinite else { return nil }
        return deltaSeconds / deltaMeters * 1_000
    }
}
