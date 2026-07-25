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
/// The chart draws each split as a deviation from this average rather than as an absolute
/// zero-anchored bar, so the thresholds that decide a bar's direction, colour, and label
/// live here where they can be unit-tested.
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
}
