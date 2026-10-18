import Foundation

/// The two comparisons that turn a run's numbers into a verdict: against what was planned,
/// and against the runner's own recent runs of the same kind.
///
/// The coach used to get the run's totals, its splits and a list of recent runs, and was
/// left to work out for itself whether 5:20 per km was good. Without a reference it fell
/// back on what is true of running in general. These lines hand it the reference, already
/// worked out, so the verdict and the three numbers under it can say "12 seconds faster
/// than planned" or "8 bpm lower than your usual easy run" instead of restating the
/// totals the runner sees at the top of the screen.
///
/// Pure arithmetic and string building over plain values, so it is unit-testable
/// without SwiftData.
enum CoachRunComparison {

    /// Fewer same-type runs than this and "your usual" is one or two runs, which is not
    /// a usual. The line says there is not enough history instead.
    static let baselineFloor = 3

    /// A pace this close to a target, in display-unit seconds, counts as on target.
    static let onTargetToleranceSeconds = 3.0

    /// A pace outside the target by no more than this, in seconds per km, is close to plan:
    /// worth naming, not worth changing the next run for. About 10 seconds per mile.
    ///
    /// Without it the plan line said "7 seconds faster than the planned 8:55–9:11" with
    /// the same weight as a minute too fast, and the coach told a runner who was nearly on
    /// target to slow down.
    static let closeToPlanSecondsPerKm = 6.0

    /// Added to the usual line when the plan set a pace, so the coach does not judge the
    /// pace twice and let the usual overrule the plan.
    static let planSetsPaceNote = "The plan set this run's pace, so use the usual to read "
        + "heart rate and fitness, not to judge whether the pace was right."

    // MARK: Plan

    /// How the run compared with its planned session, e.g.
    /// "Pace 5:12 min/km, inside the planned 5:05–5:20 min/km. Distance 8.1 km of 8.0 km planned."
    ///
    /// - Returns: `nil` when the plan carried no pace or distance target to compare with.
    static func planLine(
        actualPaceSecondsPerKm: Double,
        actualDistanceMeters: Double,
        targetPaceLower: Double?,
        targetPaceUpper: Double?,
        targetDistanceMeters: Double?,
        unit: UnitPreference
    ) -> String? {
        var parts: [String] = []

        if let lower = targetPaceLower, let upper = targetPaceUpper, lower > 0, lower <= upper,
           actualPaceSecondsPerKm > 0 {
            let actual = actualPaceSecondsPerKm.paceString(unit: unit)
            let range = "\(lower.paceValueString(unit: unit))–\(upper.paceString(unit: unit))"
            let tolerance = onTargetToleranceSeconds
            let close = closeToPlanSecondsPerKm.paceSecondsValue(unit: unit)
            let actualValue = actualPaceSecondsPerKm.paceSecondsValue(unit: unit)
            let lowerValue = lower.paceSecondsValue(unit: unit)
            let upperValue = upper.paceSecondsValue(unit: unit)
            if actualValue < lowerValue - tolerance {
                let gap = Int((lowerValue - actualValue).rounded())
                let closeNote = lowerValue - actualValue <= close ? ", close enough to count as on plan" : ""
                parts.append("Pace \(actual), \(gap) seconds faster than the planned \(range)\(closeNote).")
            } else if actualValue > upperValue + tolerance {
                let gap = Int((actualValue - upperValue).rounded())
                let closeNote = actualValue - upperValue <= close ? ", close enough to count as on plan" : ""
                parts.append("Pace \(actual), \(gap) seconds slower than the planned \(range)\(closeNote).")
            } else {
                parts.append("Pace \(actual), inside the planned \(range).")
            }
        }

        if let target = targetDistanceMeters, target > 0, actualDistanceMeters > 0 {
            let percent = Int((actualDistanceMeters / target * 100).rounded())
            parts.append(
                "Distance \(actualDistanceMeters.distanceString(unit: unit)) of "
                    + "\(target.distanceString(unit: unit)) planned (\(percent)%)."
            )
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Usual for this kind of run

    /// The runner's recent runs of one type, averaged.
    struct Baseline: Equatable, Sendable {
        let runCount: Int
        let paceSecondsPerKm: Double
        /// Average of the runs that recorded heart rate; `nil` when fewer than
        /// `baselineFloor` did.
        let heartRate: Double?
        let distanceMeters: Double
    }

    /// One recent run's numbers, as the baseline needs them.
    struct Sample: Sendable {
        let paceSecondsPerKm: Double
        let heartRate: Double?
        let distanceMeters: Double
    }

    /// The average of `samples`, or `nil` when there are fewer than `baselineFloor` with a
    /// usable pace.
    static func baseline(from samples: [Sample]) -> Baseline? {
        let usable = samples.filter { $0.paceSecondsPerKm > 0 && $0.distanceMeters > 0 }
        guard usable.count >= baselineFloor else { return nil }

        let count = Double(usable.count)
        let heartRates = usable.compactMap(\.heartRate).filter { $0 > 0 }
        return Baseline(
            runCount: usable.count,
            paceSecondsPerKm: usable.reduce(0) { $0 + $1.paceSecondsPerKm } / count,
            heartRate: heartRates.count >= baselineFloor
                ? heartRates.reduce(0, +) / Double(heartRates.count)
                : nil,
            distanceMeters: usable.reduce(0) { $0 + $1.distanceMeters } / count
        )
    }

    /// This run against the runner's usual for its type, e.g.
    /// "Your last 5 easy runs averaged 6:05 min/km at 142 bpm over 7.2 km. This one:
    /// 9 seconds faster per km, 4 bpm lower."
    ///
    /// Pace and heart rate together are the point: faster at the same heart rate, or the
    /// same pace at a lower one, is fitness; faster at a much higher one is just harder.
    static func baselineLine(
        typeName: String,
        currentPaceSecondsPerKm: Double,
        currentHeartRate: Double?,
        baseline: Baseline?,
        unit: UnitPreference
    ) -> String {
        let type = typeName.lowercased()
        guard let baseline else {
            return "Fewer than \(baselineFloor) recent \(type) runs, so there is no usual to compare with."
        }

        let hrClause = baseline.heartRate.map { " at \(Int($0.rounded())) bpm" } ?? ""
        let usual = "Your last \(baseline.runCount) \(type) runs averaged "
            + "\(baseline.paceSecondsPerKm.paceString(unit: unit))\(hrClause) over "
            + "\(baseline.distanceMeters.distanceString(unit: unit))."

        var deltas: [String] = []
        if currentPaceSecondsPerKm > 0 {
            let delta = currentPaceSecondsPerKm.paceSecondsValue(unit: unit)
                - baseline.paceSecondsPerKm.paceSecondsValue(unit: unit)
            let seconds = Int(abs(delta).rounded())
            let per = "per \(unit.distanceLabel)"
            if seconds < Int(onTargetToleranceSeconds) {
                deltas.append("the same pace")
            } else {
                deltas.append("\(seconds) seconds \(delta < 0 ? "faster" : "slower") \(per)")
            }
        }
        if let current = currentHeartRate, current > 0, let usualHR = baseline.heartRate {
            let delta = Int((current - usualHR).rounded())
            if delta == 0 {
                deltas.append("the same heart rate")
            } else {
                deltas.append("\(abs(delta)) bpm \(delta < 0 ? "lower" : "higher")")
            }
        }

        return deltas.isEmpty ? usual : "\(usual) This one: \(deltas.joined(separator: ", "))."
    }
}
