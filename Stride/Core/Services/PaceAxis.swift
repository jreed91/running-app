import Foundation

// MARK: - PaceAxis

/// Where a pace chart puts its axis labels: on whole minutes of the runner's unit, or on
/// half or quarter minutes when the data spans less.
///
/// Charts' automatic ticks are round numbers of *seconds per km*. Shown in minutes per
/// mile, those land on 8:02, 9:23, 10:43, which nobody reads as a pace. These ticks are
/// chosen in the display unit and converted back, so they read 9:00, 10:00, 11:00.
///
/// Pure and `Sendable`, so the Linux toolchain can test it.
enum PaceAxis {

    /// Steps tried, in display seconds, largest first.
    private static let steps: [Double] = [300, 120, 60, 30, 15]

    /// Tick values in seconds per km, slowest last, for data between `lower` and `upper`
    /// seconds per km. `factor` turns seconds per km into display seconds (1 for km,
    /// 1.60934 for miles; `Double.paceSecondsValue(unit:)` of 1).
    ///
    /// Picks the largest step that puts three to `maxTicks` ticks inside the data, else the
    /// largest that puts two. Empty when the range is not a usable pace.
    static func ticks(
        lowerSecondsPerKm lower: Double,
        upperSecondsPerKm upper: Double,
        factor: Double,
        maxTicks: Int = 5
    ) -> [Double] {
        guard lower.isFinite, upper.isFinite, lower > 0, upper >= lower, factor > 0 else { return [] }
        let lo = lower * factor
        let hi = upper * factor

        func inside(_ step: Double) -> [Double] {
            var values: [Double] = []
            var tick = (lo / step).rounded(.up) * step
            while tick <= hi + 0.000_1 {
                values.append(tick)
                tick += step
            }
            return values
        }

        let candidates = steps.map(inside).filter { $0.count <= maxTicks }
        var chosen = candidates.first { $0.count >= 3 }
            ?? candidates.first { $0.count == 2 }
            ?? candidates.first { !$0.isEmpty }
            ?? []
        // A range narrower than every step: label the middle so the axis is never blank.
        if chosen.isEmpty {
            let middle = ((lo + hi) / 2 / 15).rounded() * 15
            chosen = [middle]
        }
        return chosen.map { $0 / factor }
    }

    /// "9:00" for a tick, rounded to the second in the display unit. Truncating, as
    /// `paceValueString` does, can turn 540 display seconds into "8:59" after the round
    /// trip through seconds per km.
    static func label(secondsPerKm: Double, factor: Double) -> String {
        guard secondsPerKm.isFinite, secondsPerKm > 0, factor > 0 else { return "--:--" }
        let total = Int((secondsPerKm * factor).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Round-number ticks for any other measure (heart rate, VDOT, cadence): steps of
    /// 1, 2, 5, 10 and so on, three to `maxTicks` of them inside the data where possible.
    static func roundTicks(lower: Double, upper: Double, maxTicks: Int = 5) -> [Double] {
        guard lower.isFinite, upper.isFinite, upper >= lower else { return [] }
        let steps: [Double] = [100, 50, 20, 10, 5, 2, 1, 0.5]
        func inside(_ step: Double) -> [Double] {
            var values: [Double] = []
            var tick = (lower / step).rounded(.up) * step
            while tick <= upper + 0.000_1 {
                values.append(tick)
                tick += step
            }
            return values
        }
        let candidates = steps.map(inside).filter { $0.count <= maxTicks }
        if let chosen = candidates.first(where: { $0.count >= 3 })
            ?? candidates.first(where: { $0.count == 2 })
            ?? candidates.first(where: { !$0.isEmpty }) {
            return chosen
        }
        return [((lower + upper) / 2).rounded()]
    }
}
