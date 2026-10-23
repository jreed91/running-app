import Foundation

/// How one split's pace compares with the run's own average split pace.
enum SplitPaceComparison: Sendable, Equatable {
    case faster
    case onPace
    case slower
}

/// The math behind the split-pace chart: the run's own average split pace, and how far each
/// split sat from it.
///
/// The chart draws each split's pace as a line against this average, on a scale fitted
/// here, so the thresholds that decide a point's colour, the scale and the headline live
/// here where they can be unit-tested.
enum SplitPaceStats {

    /// Splits inside this many seconds per display unit of the average read as on-pace:
    /// that is within normal GPS and terrain noise, and colouring it as a fast or slow
    /// split would make an evenly-run session look ragged.
    static let onPaceToleranceSeconds: Double = 3

    /// Mean pace across the splits that recorded one, in seconds per kilometre. Nil when no
    /// split carries a usable pace.
    static func averagePaceSecondsPerKm(_ splits: [Split]) -> Double? {
        let paces = splits.map(\.paceSecondsPerKm).filter { $0 > 0 && $0.isFinite }
        guard !paces.isEmpty else { return nil }
        return paces.reduce(0, +) / Double(paces.count)
    }

    /// Signed gap from the average, in display-unit seconds. Negative is faster.
    static func deltaSeconds(pace: Double, average: Double, unit: UnitPreference) -> Double {
        (pace - average).paceSecondsValue(unit: unit)
    }

    static func comparison(pace: Double, average: Double, unit: UnitPreference) -> SplitPaceComparison {
        let delta = deltaSeconds(pace: pace, average: average, unit: unit)
        if delta <= -onPaceToleranceSeconds { return .faster }
        if delta >= onPaceToleranceSeconds { return .slower }
        return .onPace
    }

    /// The gap in words, for the chart's selection tooltip: "12s faster than avg".
    static func deltaLabel(pace: Double, average: Double, unit: UnitPreference) -> String {
        let delta = deltaSeconds(pace: pace, average: average, unit: unit)
        let seconds = Int(abs(delta).rounded())
        guard seconds > 0 else { return "on average pace" }
        return delta < 0 ? "\(seconds)s faster than avg" : "\(seconds)s slower than avg"
    }

    // MARK: Chart scale

    /// The pace chart never shows less than this either side of the average, in seconds
    /// per kilometre (about 24 s/mi). An evenly run session spreads a few seconds; drawn
    /// edge to edge that noise would look like a ragged run.
    static let minimumChartHalfRangeSeconds: Double = 15

    /// Nor more than this (about 2:25 per mile). A bucket that includes a stop or a walk
    /// can sit minutes off the average, and a scale stretched to fit it pressed every other
    /// bucket into one flat band, which is what the old bars did. Such a bucket is drawn
    /// at the slow edge instead (`clamped`), and its tooltip still gives its real pace.
    static let maximumChartHalfRangeSeconds: Double = 90

    /// Headroom past the furthest bucket, so its marker does not sit on the chart's edge.
    static let chartPadding: Double = 1.15

    /// The pace chart's y domain in seconds per kilometre: centred on the run's average so
    /// the dashed line sits mid-chart, and wide enough for the furthest bucket within the
    /// limits above. Paces that are not usable (zero, infinite) do not widen it.
    static func chartDomain(paces: [Double], average: Double) -> ClosedRange<Double> {
        let furthest = paces
            .filter { $0 > 0 && $0.isFinite }
            .map { abs($0 - average) }
            .max() ?? 0
        let half = min(
            max(furthest * chartPadding, minimumChartHalfRangeSeconds),
            maximumChartHalfRangeSeconds
        )
        return (average - half)...(average + half)
    }

    /// `pace` held inside `domain`, for plotting. A pace outside it is drawn on the edge it
    /// passed rather than off the chart.
    static func clamped(_ pace: Double, to domain: ClosedRange<Double>) -> Double {
        min(max(pace, domain.lowerBound), domain.upperBound)
    }

    // MARK: Run shape

    /// How the second half of a run compared with the first: the one-line answer the pace
    /// chart opens with, so the card says what the line means before anyone reads it.
    enum Shape: Equatable, Sendable {
        /// The halves sat within `evenToleranceSeconds` of each other.
        case even
        /// The second half was faster by this many display-unit seconds.
        case fasterFinish(seconds: Int)
        /// The second half was slower by this many display-unit seconds.
        case slowerFinish(seconds: Int)
    }

    /// Halves within this many seconds per display unit read as an even run.
    static let evenToleranceSeconds: Double = 5

    /// Compares the mean pace of the first half of `splits` with the second. With an odd
    /// count the middle bucket belongs to neither half. Nil with fewer than two usable
    /// splits, where there are no halves to compare.
    static func shape(_ splits: [Split], unit: UnitPreference) -> Shape? {
        let paces = splits.map(\.paceSecondsPerKm).filter { $0 > 0 && $0.isFinite }
        guard paces.count >= 2 else { return nil }
        let halfCount = paces.count / 2
        let first = paces.prefix(halfCount).reduce(0, +) / Double(halfCount)
        let second = paces.suffix(halfCount).reduce(0, +) / Double(halfCount)
        let delta = deltaSeconds(pace: second, average: first, unit: unit)
        guard abs(delta) >= evenToleranceSeconds else { return .even }
        let seconds = Int(abs(delta).rounded())
        return delta < 0 ? .fasterFinish(seconds: seconds) : .slowerFinish(seconds: seconds)
    }

    /// The shape in words: "Even pace start to finish", "Second half 18s/mi faster".
    static func shapeHeadline(_ shape: Shape, unit: UnitPreference) -> String {
        switch shape {
        case .even:
            return "Even pace start to finish"
        case .fasterFinish(let seconds):
            return "Second half \(seconds)s/\(unit.distanceLabel) faster"
        case .slowerFinish(let seconds):
            return "Second half \(seconds)s/\(unit.distanceLabel) slower"
        }
    }
}
