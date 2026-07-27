import Foundation

/// Formats a completed run's splits and time-in-heart-rate-zone breakdown as text for the
/// AI coach prompt, plus short human sentences for the local (non-model) summary.
///
/// The run-summary screen shows the split charts, the split table, and the zone breakdown
/// directly above the coach card, so the coaching read has to be grounded in the same
/// numbers the runner just scrolled past. Pure arithmetic and string building — no UI, no
/// persistence — so it stays unit-testable.
enum CoachRunBreakdown {

    /// How many per-split rows the prompt carries.
    ///
    /// Longer runs keep their opening and closing splits and drop the middle rather than
    /// truncating at the front: the closing splits are exactly what the coach reads for
    /// fade, and a front-truncated marathon hid all of them.
    static let splitLineLimit = 20

    // MARK: - Splits

    /// The per-split table as prompt lines, e.g. `km 3: pace 5:10 min/km, hr 152, elev 12 m`.
    static func splitSection(
        splits: [Split],
        unit: UnitPreference,
        splitLabel: String,
        limit: Int = splitLineLimit
    ) -> String {
        guard !splits.isEmpty else { return "No split data." }
        guard splits.count > limit, limit >= 2 else {
            return splits.map { splitLine($0, unit: unit, splitLabel: splitLabel) }.joined(separator: "\n")
        }

        let head = limit / 2
        let tail = limit - head
        let lines: [String] = splits.prefix(head).map { splitLine($0, unit: unit, splitLabel: splitLabel) }
            + ["(\(splits.count - limit) middle splits omitted)"]
            + splits.suffix(tail).map { splitLine($0, unit: unit, splitLabel: splitLabel) }
        return lines.joined(separator: "\n")
    }

    private static func splitLine(_ split: Split, unit: UnitPreference, splitLabel: String) -> String {
        let hr = split.heartRate.map { "\(Int($0.rounded()))" } ?? "n/a"
        return "\(splitLabel) \(split.kilometer): pace \(split.paceSecondsPerKm.paceString(unit: unit)), "
            + "hr \(hr), elev \(split.elevationGainMeters.elevationString(unit: unit))"
    }

    /// The shape of a run's split pacing: extremes, spread, consistency, and how the second
    /// half compared with the first. All second values are in *display*-unit seconds
    /// (per mile for imperial), so they read the same way as the paces beside them.
    struct SplitTrend: Sendable, Equatable {
        let fastest: Split
        let slowest: Split
        /// Gap between the slowest and the fastest split.
        let spreadSeconds: Double
        /// Standard deviation of split pace.
        let consistencySeconds: Double
        /// Second-half average minus first-half average. Negative means the run finished
        /// faster than it started.
        let secondHalfDeltaSeconds: Double
    }

    static func splitTrend(splits: [Split], unit: UnitPreference) -> SplitTrend? {
        let paced = splits.filter { $0.paceSecondsPerKm > 0 && $0.paceSecondsPerKm.isFinite }
        guard paced.count >= 2,
              let fastest = paced.min(by: { $0.paceSecondsPerKm < $1.paceSecondsPerKm }),
              let slowest = paced.max(by: { $0.paceSecondsPerKm < $1.paceSecondsPerKm }) else {
            return nil
        }

        let paces = paced.map(\.paceSecondsPerKm)
        let meanPace = average(of: paces)
        let variance = paces.reduce(0) { $0 + ($1 - meanPace) * ($1 - meanPace) } / Double(paces.count)
        // Odd split counts give the middle split to the second half, matching how the
        // closing-fade read is normally framed.
        let half = paced.count / 2
        let firstHalf = average(of: paces.prefix(half))
        let secondHalf = average(of: paces.suffix(paces.count - half))

        return SplitTrend(
            fastest: fastest,
            slowest: slowest,
            spreadSeconds: (slowest.paceSecondsPerKm - fastest.paceSecondsPerKm).paceSecondsValue(unit: unit),
            consistencySeconds: variance.squareRoot().paceSecondsValue(unit: unit),
            secondHalfDeltaSeconds: (secondHalf - firstHalf).paceSecondsValue(unit: unit)
        )
    }

    /// The full trend line for the prompt.
    static func splitTrendLine(_ trend: SplitTrend, splitLabel: String, unit: UnitPreference) -> String {
        "fastest \(splitLabel) \(trend.fastest.kilometer) at \(trend.fastest.paceSecondsPerKm.paceString(unit: unit)), "
            + "slowest \(splitLabel) \(trend.slowest.kilometer) at \(trend.slowest.paceSecondsPerKm.paceString(unit: unit)), "
            + "spread \(secondsString(trend.spreadSeconds)), consistency ±\(secondsString(trend.consistencySeconds)), "
            + halfComparison(trend, unit: unit)
    }

    /// Range and consistency only — for summaries that already carry a pace-fade sentence.
    static func splitRangeSentence(_ trend: SplitTrend, splitLabel: String, unit: UnitPreference) -> String {
        splitRangeFragment(trend, splitLabel: splitLabel, unit: unit) + "."
    }

    /// Range, consistency, and the half-to-half comparison as one sentence.
    static func splitTrendSentence(_ trend: SplitTrend, splitLabel: String, unit: UnitPreference) -> String {
        splitRangeFragment(trend, splitLabel: splitLabel, unit: unit)
            + ", and the \(halfComparison(trend, unit: unit))."
    }

    private static func splitRangeFragment(
        _ trend: SplitTrend,
        splitLabel: String,
        unit: UnitPreference
    ) -> String {
        "Splits ran from \(trend.fastest.paceSecondsPerKm.paceString(unit: unit)) "
            + "(\(splitLabel) \(trend.fastest.kilometer)) to \(trend.slowest.paceSecondsPerKm.paceString(unit: unit)) "
            + "(\(splitLabel) \(trend.slowest.kilometer)), ±\(secondsString(trend.consistencySeconds)) typical variation"
    }

    private static func halfComparison(_ trend: SplitTrend, unit: UnitPreference) -> String {
        let magnitude = abs(trend.secondHalfDeltaSeconds)
        // Under ~3 s/unit between halves is inside normal GPS and terrain noise, so it is
        // reported as an even run rather than as a split in either direction.
        guard magnitude >= 3 else { return "second half held the first-half pace" }
        let direction = trend.secondHalfDeltaSeconds < 0
            ? "faster than the first (negative split)"
            : "slower than the first (positive split)"
        return "second half ran \(secondsString(magnitude))/\(unit.distanceLabel) \(direction)"
    }

    // MARK: - Heart-rate zones

    /// The time-in-zone table as prompt lines, hardest zone first — the order the zone rows
    /// use on screen. Zones the runner never entered are left out.
    static func zoneSection(_ slices: [HRZoneSlice], maxHR: Double?) -> String {
        let active = slices.filter { $0.seconds > 0 }
        let total = active.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return "No heart-rate zone data." }

        let rows = active
            .sorted { $0.zone.rawValue > $1.zone.rawValue }
            .map { slice -> String in
                let percent = Int(((slice.seconds / total) * 100).rounded())
                let bounds = maxHR.map { maxHR -> String in
                    let range = HeartRateZoneService.bounds(for: slice.zone, maxHR: maxHR)
                    return " (\(range.lower)-\(range.upper) bpm)"
                } ?? ""
                return "\(slice.zone.shortName) \(slice.zone.label)\(bounds): \(slice.seconds.durationString) (\(percent)%)"
            }
        let header = maxHR.map { "Zones derived from max HR \(Int($0.rounded())) bpm." }
        return ([header].compactMap { $0 } + rows).joined(separator: "\n")
    }

    /// Where the run's heart rate actually sat, as one sentence.
    static func zoneSentence(_ slices: [HRZoneSlice]) -> String? {
        let active = slices.filter { $0.seconds > 0 }
        let total = active.reduce(0) { $0 + $1.seconds }
        guard total > 0, let dominant = active.max(by: { $0.seconds < $1.seconds }) else { return nil }

        let dominantPercent = Int(((dominant.seconds / total) * 100).rounded())
        var sentence = "Heart rate sat mostly in \(dominant.zone.shortName) "
            + "(\(dominant.zone.label.lowercased())) for \(dominantPercent)% of the run"
        if let hardShare = hardEffortShare(slices), hardShare > 0 {
            sentence += ", with \(Int((hardShare * 100).rounded()))% at threshold or harder"
        }
        return sentence + "."
    }

    /// Fraction of recorded time spent in Z4–Z5, or nil when there is no zone data.
    static func hardEffortShare(_ slices: [HRZoneSlice]) -> Double? {
        let total = slices.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return nil }
        let hard = slices
            .filter { $0.zone.rawValue >= HRZone.z4.rawValue }
            .reduce(0) { $0 + $1.seconds }
        return hard / total
    }

    // MARK: - Cadence (A5)

    /// Below this, adding steps is the standard first thing to try — it shortens the
    /// stride and moves the footstrike back under the hips. Well under the ~180 spm
    /// figure that gets quoted, because that number is an elite average and a recreational
    /// runner at 168 has nothing to fix.
    static let lowCadenceStepsPerMinute: Double = 160

    /// The run's cadence as one sentence, or `nil` when the run carries none.
    ///
    /// Reported as an observation, not a diagnosis: cadence varies with pace, terrain and
    /// height, so the sentence says what it was and — only when it is low — what that
    /// usually means.
    static func cadenceSentence(_ stepsPerMinute: Double?) -> String? {
        guard let cadence = stepsPerMinute, cadence > 0, cadence.isFinite else { return nil }
        let rounded = Int(cadence.rounded())
        guard cadence < lowCadenceStepsPerMinute else {
            return "Average cadence was \(rounded) steps per minute."
        }
        return "Average cadence was \(rounded) steps per minute, on the low side — "
            + "usually a sign of overstriding."
    }

    /// A cadence focus item for the coach, when there is one worth giving.
    ///
    /// Only for low cadence on an easy or long run: those are the sessions where a runner
    /// has the attention to change something about their form, and where doing so does not
    /// cost them the workout's own target.
    static func cadenceFocus(_ stepsPerMinute: Double?, workoutType: WorkoutType) -> String? {
        guard let cadence = stepsPerMinute, cadence > 0, cadence.isFinite,
              cadence < lowCadenceStepsPerMinute,
              workoutType == .easy || workoutType == .longRun else { return nil }
        return "Try lifting cadence a few steps per minute on easy runs — "
            + "shorter, quicker strides at the same pace, from \(Int(cadence.rounded())) spm."
    }

    // MARK: - Helpers

    private static func secondsString(_ value: Double) -> String {
        "\(Int(value.rounded()))s"
    }

    private static func average(of values: some Collection<Double>) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
