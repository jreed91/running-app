import Foundation

// MARK: - SplitAnnouncement

/// The sentence a runner *hears* when a split closes mid-run.
///
/// The run HUD is a heads-down screen: U4 gave it haptics so state changes are felt,
/// but a haptic can only say "something happened" — it cannot say *what the split was*.
/// Speech is the standard answer to the same problem, and it is the one channel that
/// reaches a runner whose phone is in an armband or a pocket.
///
/// Pure and separate from the speaking itself (``RunVoiceCoach``) so the wording is
/// unit-testable, the way ``SpokenMetric`` and ``ChartAccessibility`` are. The phrase is
/// built out of `SpokenMetric` rather than the on-screen strings, so a spoken pace says
/// "minutes per kilometre" and not "slash km".
enum SplitAnnouncement {

    /// How a closing split's pace compared to the run's target.
    ///
    /// Deltas are in seconds *per display unit*, so an imperial runner hears the number
    /// they would compute from the paces they see, not a per-km figure relabelled.
    enum PaceVerdict: Equatable, Sendable {
        case onPace
        case fast(bySeconds: Int)
        case slow(bySeconds: Int)
    }

    /// How far outside the target band a split has to land before the announcement
    /// mentions it, in seconds per kilometre.
    ///
    /// Matches ``WorkoutPaceAlert``'s default tolerance, which is the band a scheduled
    /// Watch workout coaches to — so the phone and the Watch agree about what counts as
    /// on pace. GPS pace inside a single kilometre is not accurate to the second, and a
    /// runner told "2 seconds slow" would be being corrected by the noise.
    static let toleranceSecondsPerKm: Double = 8

    /// The full announcement for a split that has just closed, or `nil` when there is
    /// nothing worth saying.
    ///
    /// - Parameters:
    ///   - splitNumber: 1-based index of the completed split — the kilometre or mile
    ///     the runner has just finished.
    ///   - paceSecondsPerKm: the split's own pace, always in seconds per kilometre
    ///     (the app's internal pace unit) regardless of `unit`.
    ///   - unit: the runner's display unit, which decides both the noun ("kilometre" /
    ///     "mile") and the units the pace and any delta are spoken in.
    ///   - targetPaceSecondsPerKm: the band this run is being coached to, when there is
    ///     one — a scheduled workout's target range, or a guided step's single target
    ///     passed as `pace...pace`. A free run has none and hears no verdict.
    static func phrase(
        splitNumber: Int,
        paceSecondsPerKm: Double,
        unit: UnitPreference,
        targetPaceSecondsPerKm: ClosedRange<Double>? = nil
    ) -> String? {
        guard splitNumber > 0 else { return nil }

        var sentences = [milestone(splitNumber: splitNumber, unit: unit)]

        // An unusable pace drops its clause rather than the whole announcement: the
        // milestone is still worth hearing, and `paceString` would otherwise be spoken
        // as a run of dashes.
        if paceSecondsPerKm > 0, paceSecondsPerKm.isFinite {
            sentences.append(SpokenMetric.spoken(measurement: paceSecondsPerKm.paceString(unit: unit)) + ".")
            if let target = targetPaceSecondsPerKm,
               let paceVerdict = Self.verdict(paceSecondsPerKm: paceSecondsPerKm, target: target, unit: unit) {
                sentences.append(sentence(for: paceVerdict))
            }
        }

        return sentences.joined(separator: " ")
    }

    /// "Kilometre 5." / "Mile 5." — the completed bucket, named in the runner's unit.
    ///
    /// Spelled the way ``SpokenMetric`` spells it ("kilometre"), not the way the Units
    /// setting does ("Kilometers"): the two halves land in the same spoken sentence.
    static func milestone(splitNumber: Int, unit: UnitPreference) -> String {
        switch unit {
        case .metric:
            return String(localized: "Kilometre \(splitNumber).", comment: "Spoken split milestone, metric")
        case .imperial:
            return String(localized: "Mile \(splitNumber).", comment: "Spoken split milestone, imperial")
        }
    }

    /// Where a split's pace landed relative to the target band, or `nil` when it landed
    /// inside the band widened by ``toleranceSecondsPerKm`` — i.e. close enough that the
    /// difference is measurement noise.
    ///
    /// Pace is inverted: a *smaller* seconds-per-unit figure is *faster*, so undershooting
    /// the band's lower bound is `.fast`.
    static func verdict(
        paceSecondsPerKm: Double,
        target: ClosedRange<Double>,
        unit: UnitPreference
    ) -> PaceVerdict? {
        guard paceSecondsPerKm > 0, paceSecondsPerKm.isFinite else { return nil }
        let pace = paceSecondsPerKm.paceSecondsValue(unit: unit)
        let low = target.lowerBound.paceSecondsValue(unit: unit)
        let high = target.upperBound.paceSecondsValue(unit: unit)
        let tolerance = toleranceSecondsPerKm.paceSecondsValue(unit: unit)

        if pace < low - tolerance {
            return .fast(bySeconds: Int((low - pace).rounded()))
        }
        if pace > high + tolerance {
            return .slow(bySeconds: Int((pace - high).rounded()))
        }
        return .onPace
    }

    private static func sentence(for verdict: PaceVerdict) -> String {
        switch verdict {
        case .onPace:
            return String(localized: "On pace.", comment: "Spoken verdict when a split matched its target pace")
        case .fast(let seconds):
            return String(localized: "\(seconds) seconds fast.", comment: "Spoken verdict when a split was quicker than its target pace")
        case .slow(let seconds):
            return String(localized: "\(seconds) seconds slow.", comment: "Spoken verdict when a split was slower than its target pace")
        }
    }
}
