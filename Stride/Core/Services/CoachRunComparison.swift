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

    // MARK: What the planned pace is for

    /// What a planned session's pace target is a target for.
    ///
    /// An easy run's band is for the whole run. A tempo or interval session's is for the
    /// work only: the plan puts a warm-up and a cool-down around it at easy pace, and
    /// recoveries between reps, and the run's average pace takes all of those in. Held
    /// against the work pace, a tempo run exactly to plan read as half a minute per km too
    /// slow, and the coach told the runner to speed up.
    enum PlannedPaceScope: Equatable, Sendable {
        /// The whole run is meant to be at the planned pace: easy and long runs, races, and
        /// a tempo with no warm-up or cool-down around it.
        case wholeRun
        /// Only the work is. `continuousMeters` is its length when it is one unbroken block
        /// (a tempo between a warm-up and a cool-down), and nil for reps with recoveries
        /// between them or a block of unknown length.
        case workOnly(continuousMeters: Double?)
    }

    /// The scope of a planned session's pace target, from its type and its structure.
    static func plannedPaceScope(
        type: WorkoutType,
        structure: WorkoutStructure?,
        intervals: [WorkoutInterval]
    ) -> PlannedPaceScope {
        switch type {
        case .interval:
            return .workOnly(continuousMeters: nil)
        case .tempo:
            guard intervals.isEmpty else { return .workOnly(continuousMeters: nil) }
            guard let structure else { return .wholeRun }
            let isOneBlock = structure.mainSets.count == 1 && structure.mainSets[0].repetitions == 1
            guard isOneBlock else { return .workOnly(continuousMeters: nil) }
            guard hasLength(structure.warmup) || hasLength(structure.cooldown) else { return .wholeRun }
            let meters = structure.mainSets[0].workSegment.distanceMeters
            return .workOnly(continuousMeters: meters.flatMap { $0 > 0 ? $0 : nil })
        default:
            return .wholeRun
        }
    }

    private static func hasLength(_ segment: WorkoutSegment) -> Bool {
        (segment.distanceMeters ?? 0) > 0 || (segment.durationSeconds ?? 0) > 0
    }

    /// A block's pace, read off the splits.
    struct BlockPace: Equatable, Sendable {
        let paceSecondsPerKm: Double
        /// How much of the run the pace was read from: a whole number of splits.
        let meters: Double
    }

    /// The pace of a tempo block between a warm-up and a cool-down, from the fastest run of
    /// whole splits that fits inside it; nil when the block is too short to hold a whole
    /// split or the run has too few splits to leave any out.
    ///
    /// A block that starts and ends partway through a split always holds at least one
    /// whole split fewer than its length, so the window is that many: wherever the block
    /// fell, the window can sit entirely inside it, clear of the slower warm-up and
    /// cool-down. The fastest window is the block's when the run went to plan; picking the
    /// fastest of a few near-equal windows biases it quick by a second or two at most.
    ///
    /// - Parameter splitMeters: the length of one split, which is the run's own split
    ///   unit (`RunWorkout.splitUnit`), not necessarily the display unit.
    static func blockPace(splits: [Split], blockMeters: Double, splitMeters: Double) -> BlockPace? {
        guard blockMeters > 0, splitMeters > 0 else { return nil }
        let paces = splits
            .filter { $0.paceSecondsPerKm > 0 && $0.paceSecondsPerKm.isFinite }
            .sorted { $0.kilometer < $1.kilometer }
            .map(\.paceSecondsPerKm)
        let window = Int((blockMeters / splitMeters).rounded(.down)) - 1
        guard window >= 1, window < paces.count else { return nil }

        var sum = paces.prefix(window).reduce(0, +)
        var fastest = sum
        for end in window..<paces.count {
            sum += paces[end] - paces[end - window]
            fastest = min(fastest, sum)
        }
        return BlockPace(paceSecondsPerKm: fastest / Double(window), meters: Double(window) * splitMeters)
    }

    /// `blockPace(splits:blockMeters:splitMeters:)` for a scope with a block to find.
    static func blockPace(for scope: PlannedPaceScope, splits: [Split], splitMeters: Double) -> BlockPace? {
        guard case .workOnly(let meters?) = scope else { return nil }
        return blockPace(splits: splits, blockMeters: meters, splitMeters: splitMeters)
    }

    // MARK: Plan

    /// How the run compared with its planned session, e.g.
    /// "Pace 5:12 min/km, inside the planned 5:05–5:20 min/km. Distance 8.1 km of 8.0 km planned."
    ///
    /// - Parameters:
    ///   - paceScope: what the planned pace is for. When it is only the work, the run's
    ///     average is never held against it: `blockPace` is, when there is one, and the
    ///     line says why the average is left out.
    ///   - blockPace: the work block's pace from the splits, for a `.workOnly` scope.
    /// - Returns: `nil` when the plan carried no pace or distance target to compare with.
    static func planLine(
        actualPaceSecondsPerKm: Double,
        actualDistanceMeters: Double,
        targetPaceLower: Double?,
        targetPaceUpper: Double?,
        targetDistanceMeters: Double?,
        unit: UnitPreference,
        paceScope: PlannedPaceScope = .wholeRun,
        blockPace: BlockPace? = nil
    ) -> String? {
        var parts: [String] = []

        if let lower = targetPaceLower, let upper = targetPaceUpper, lower > 0, lower <= upper {
            switch paceScope {
            case .wholeRun:
                if actualPaceSecondsPerKm > 0 {
                    let verdict = paceAgainstRange(actualPaceSecondsPerKm, lower: lower, upper: upper, unit: unit)
                    parts.append("Pace \(actualPaceSecondsPerKm.paceString(unit: unit)), \(verdict).")
                }
            case .workOnly:
                if let blockPace {
                    let verdict = paceAgainstRange(blockPace.paceSecondsPerKm, lower: lower, upper: upper, unit: unit)
                    parts.append(
                        "The planned pace is for the block between the warm-up and the cool-down. "
                            + "The fastest \(blockPace.meters.distanceString(unit: unit)) of splits ran "
                            + "\(blockPace.paceSecondsPerKm.paceString(unit: unit)), \(verdict)."
                    )
                    parts.append(
                        "The whole run's average pace also takes in the warm-up and the cool-down, "
                            + "so it is not the pace to judge."
                    )
                } else {
                    let range = "\(lower.paceValueString(unit: unit))–\(upper.paceString(unit: unit))"
                    parts.append(
                        "The planned \(range) is the pace for the work, not the whole run. "
                            + "The whole run's average pace also takes in the easy running around the "
                            + "work, so it cannot show whether the work was on pace."
                    )
                }
            }
        }

        if let target = targetDistanceMeters, target > 0, actualDistanceMeters > 0 {
            let percent = Int((actualDistanceMeters / target * 100).rounded())
            parts.append(
                "Distance \(actualDistanceMeters.distanceString(unit: unit)) of "
                    + "\(target.distanceString(unit: unit)) planned (\(percent)%)."
            )
            // On a tempo or interval session the extra is whole-run distance: nothing says
            // when it was run. Without this the coach read "2.5 of 1.9 mi" as "added 0.6
            // miles at a hard effort", called it "Work distance" and made it the verdict.
            if case .workOnly = paceScope, actualDistanceMeters > target * 1.05 {
                let extra = (actualDistanceMeters - target).distanceString(unit: unit)
                parts.append(
                    "That is the whole run, warm-up and cool-down included, not the work. "
                        + "Nothing here says when the extra \(extra) was run or how hard; it is most "
                        + "likely easy running before or after the work."
                )
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "inside the planned 5:05–5:20 min/km", or "12 seconds faster than the planned
    /// 5:05–5:20 min/km", with ", close enough to count as on plan" on a small miss.
    private static func paceAgainstRange(
        _ pace: Double,
        lower: Double,
        upper: Double,
        unit: UnitPreference
    ) -> String {
        let range = "\(lower.paceValueString(unit: unit))–\(upper.paceString(unit: unit))"
        let tolerance = onTargetToleranceSeconds
        let close = closeToPlanSecondsPerKm.paceSecondsValue(unit: unit)
        let actualValue = pace.paceSecondsValue(unit: unit)
        let lowerValue = lower.paceSecondsValue(unit: unit)
        let upperValue = upper.paceSecondsValue(unit: unit)
        if actualValue < lowerValue - tolerance {
            let gap = lowerValue - actualValue
            let closeNote = gap <= close ? ", close enough to count as on plan" : ""
            return "\(Int(gap.rounded())) seconds faster than the planned \(range)\(closeNote)"
        }
        if actualValue > upperValue + tolerance {
            let gap = actualValue - upperValue
            let closeNote = gap <= close ? ", close enough to count as on plan" : ""
            return "\(Int(gap.rounded())) seconds slower than the planned \(range)\(closeNote)"
        }
        return "inside the planned \(range)"
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
        let runs = runsPhrase(typeName)
        guard let baseline else {
            return "Fewer than \(baselineFloor) recent \(runs), so there is no usual to compare with."
        }

        let hrClause = baseline.heartRate.map { " at \(Int($0.rounded())) bpm" } ?? ""
        let usual = "Your last \(baseline.runCount) \(runs) averaged "
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

    /// "easy runs", but "long runs" and "races": the type name already says what a long
    /// run or a race is, and "long run runs" is what the line used to read.
    private static func runsPhrase(_ typeName: String) -> String {
        let type = typeName.lowercased()
        if type == "race" { return "races" }
        return type.hasSuffix("run") ? "\(type)s" : "\(type) runs"
    }
}

// MARK: - Models

extension ScheduledWorkout {
    /// What this session's pace target is for; see `CoachRunComparison.PlannedPaceScope`.
    var paceScope: CoachRunComparison.PlannedPaceScope {
        CoachRunComparison.plannedPaceScope(type: workoutType, structure: workoutStructure, intervals: intervals)
    }
}

extension RunWorkout {
    /// Whether this run's splits were all meant to be one effort, so that a slower back
    /// half is a fade and a climbing heart rate is drift.
    ///
    /// Not so for intervals, or for a tempo between a warm-up and a cool-down: there the
    /// splits climb from easy to hard and back by design. Read against the planned session
    /// this run fulfilled, since a run imported from the Watch carries a type guessed from
    /// its average pace, which is never `.interval`.
    var splitsAreOneEffort: Bool {
        let scope = scheduledWorkout?.paceScope
            ?? CoachRunComparison.plannedPaceScope(type: workoutType, structure: nil, intervals: [])
        return scope == .wholeRun
    }
}
