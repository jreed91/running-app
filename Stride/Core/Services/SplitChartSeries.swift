import Foundation

// MARK: - SplitChartSeries

/// The series the run summary's split charts actually plot, and the resolution it is
/// bucketed at.
///
/// A `Split` closes on a whole kilometre or mile because that is the number a runner wants
/// in the splits *table*. As a chart it falls apart on anything short: a one-mile run has
/// exactly one split, so "Pace per mi" and "Heart rate per mi" each drew a single marker
/// with nothing to compare it against, and a 5K drew three (N34). The distance readings the
/// splits were bucketed from are persisted now (`RunWorkout.distanceSeries`), so the charts
/// re-bucket a short run into fractions of the runner's unit — tenths of a mile for a mile
/// run — while the table keeps its whole-unit rows.
///
/// Pure and workout-agnostic on purpose: the resolution ladder is the whole behaviour worth
/// testing, and it should not need a view or a SwiftData context to check.
enum SplitChartSeries {

    // MARK: Resolution

    /// Fractions of one distance unit the charts are willing to bucket at, coarsest first.
    ///
    /// Whole unit, half, quarter, tenth. They are the fractions that survive being written
    /// on an axis: 0.5 and 0.25 and 0.1 read as distances, an eighth of a mile reads as
    /// 0.125 and stops looking like one.
    static let fractionLadder: [Double] = [1, 0.5, 0.25, 0.1]

    /// How many buckets a chart wants before it stops subdividing.
    ///
    /// Six is where a bar chart starts showing a shape rather than a reading: a 5K on
    /// half-units and a mile on tenths both clear it, and a 10K keeps its familiar
    /// whole-unit splits because it clears it already.
    static let minimumBuckets = 6

    /// The fraction of `unitLengthMeters` to bucket a run of `distanceMeters` at.
    ///
    /// The coarsest fraction that yields at least `minimumBuckets`, falling back to the
    /// finest on a run too short for any of them — a 400 m jog gets tenths and the four
    /// buckets that come with it rather than nothing at all.
    static func bucketFraction(distanceMeters: Double, unitLengthMeters: Double) -> Double {
        guard unitLengthMeters > 0, distanceMeters > 0, distanceMeters.isFinite else { return 1 }
        let fraction = fractionLadder.first { candidate in
            Int(distanceMeters / (unitLengthMeters * candidate)) >= minimumBuckets
        }
        return fraction ?? fractionLadder.last ?? 1
    }

    /// Label for one bucket in the runner's unit — "mi" at full resolution, "0.25 mi" when
    /// subdivided — used in the card's heading so it never claims a per-mile reading it is
    /// not showing.
    static func bucketLabel(fraction: Double, unit: UnitPreference) -> String {
        guard fraction < 1 else { return unit.distanceLabel }
        return "\(formattedFraction(fraction)) \(unit.distanceLabel)"
    }

    /// `0.5` / `0.25` / `0.1` without a trailing zero, and without `NumberFormatter`: these
    /// are the four values on `fractionLadder`, not arbitrary input.
    private static func formattedFraction(_ fraction: Double) -> String {
        let twoPlaces = String(format: "%.2f", fraction)
        return twoPlaces.hasSuffix("0") ? String(twoPlaces.dropLast()) : twoPlaces
    }

    // MARK: Resolved series

    /// The splits to chart, and what one of them represents.
    struct Resolved: Equatable, Sendable {
        /// Bucketed splits, in order. `kilometer` numbers the bucket, as it does on a stored
        /// split — at a finer resolution it counts fractions, so the charts label the axis
        /// from `cumulativeDistanceMeters` instead.
        var splits: [Split]
        /// The fraction of one distance unit each split covers: `1` for stored whole-unit
        /// splits, less when the series was subdivided.
        var fraction: Double
        /// Unit the buckets are measured in — the run's own `splitUnit` when its stored
        /// splits are used, so a legacy kilometre-bucketed run keeps reading in kilometres.
        var unit: UnitPreference

        /// Whether the charts are showing something finer than the stored splits.
        var isSubdivided: Bool { fraction < 1 }

        /// The card's heading suffix: "mi", or "0.1 mi" when subdivided.
        var bucketLabel: String { SplitChartSeries.bucketLabel(fraction: fraction, unit: unit) }
    }

    /// Buckets `workout` for its split charts.
    ///
    /// Falls back to the stored `splits` whenever subdividing would be a guess rather than a
    /// finer reading of the same data: a run recorded before the series was persisted has
    /// nothing to re-bucket, and a run long enough for whole-unit splits to make a chart is
    /// better off with the buckets its table already shows.
    ///
    /// - Parameters:
    ///   - workout: the run being charted.
    ///   - unit: the runner's current distance preference, used only when re-bucketing —
    ///     stored splits keep the unit they were recorded in.
    static func resolve(for workout: RunWorkout, unit: UnitPreference) -> Resolved {
        let stored = Resolved(splits: workout.splits, fraction: 1, unit: workout.splitUnit)

        let series = workout.distanceSeries
        guard !series.isEmpty else { return stored }

        let fraction = bucketFraction(
            distanceMeters: workout.distanceMeters, unitLengthMeters: unit.splitLengthMeters
        )
        guard fraction < 1 else { return stored }

        let splits = SplitBucketing.splits(
            from: series,
            splitLengthMeters: unit.splitLengthMeters * fraction,
            heartRateSamples: workout.heartRateSamples,
            totalDurationSeconds: workout.durationSeconds
        )
        // A series too sparse or too broken to bucket leaves the stored splits alone rather
        // than emptying a card that had something in it.
        guard splits.count > stored.splits.count else { return stored }
        return Resolved(splits: splits, fraction: fraction, unit: unit)
    }

    // MARK: Chart selection

    /// The split a chart selection at `bucket` refers to, out of the splits that chart
    /// actually plots.
    ///
    /// A selection is not guaranteed to name a plotted bucket. `chartXSelection` reports
    /// the position under the finger, and a chart drawn only from `LineMark`/`PointMark`
    /// scales its x axis continuously — so the value comes back from somewhere between two
    /// buckets rather than on one of them. A chart that also filters its splits (the heart
    /// rate one plots only the buckets carrying a reading) can be handed a bucket it has no
    /// mark for even when the value does land squarely on one.
    ///
    /// Matching the nearest plotted split covers both: a tooltip follows the finger to the
    /// marker beside it instead of appearing only on the exact touches that happen to
    /// resolve to a plotted bucket. Ties go to the lower bucket, so a touch exactly between
    /// two markers picks one and stays there.
    static func nearestSplit(to bucket: Int, in splits: [Split]) -> Split? {
        splits.min { abs($0.kilometer - bucket) < abs($1.kilometer - bucket) }
    }

    // MARK: Axis labels

    /// The distance a bucket ends at, in the runner's unit, for the chart's x axis.
    ///
    /// Whole-unit buckets read "3"; subdivided ones read "0.4" — the axis names distance
    /// covered rather than bucket number, which is the only thing that stays honest when a
    /// bucket is a tenth of a mile.
    static func axisLabel(cumulativeMeters: Double, unit: UnitPreference, fraction: Double) -> String {
        let distance = cumulativeMeters / unit.splitLengthMeters
        guard fraction < 1 else { return "\(Int(distance.rounded()))" }
        return String(format: "%.2f", distance)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}
