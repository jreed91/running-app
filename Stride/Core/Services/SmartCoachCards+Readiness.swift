import Foundation

// MARK: - Readiness

/// The card for a runner who has not recovered: HRV down, resting heart rate up, a short
/// night, or a week well above their usual, scored by ``RecoveryReadiness`` (B7).
///
/// It only speaks when readiness is low. A daily "you're fine" would take one of three
/// slots on most days to say nothing, and the strip is for what the runner should do
/// differently.
extension SmartCoachCards {

    /// Readiness score at which the card starts firing, and where it is as urgent as it
    /// gets. Out of 100.
    static let readinessThreshold = 60.0
    static let readinessFloor = 30.0
    /// Higher than the shared 0.2: a readiness just under the line is still a reason to
    /// ease off, and it should be able to sit above a routine fuelling note.
    static let readinessBaseScore = 0.3

    static func readinessCard(_ context: Context) -> SmartCoachCard? {
        guard let readiness = context.readiness else { return nil }
        let score = SmartCoachCard.inverseUrgency(
            Double(readiness.score),
            threshold: readinessThreshold,
            saturatingAt: readinessFloor,
            base: readinessBaseScore
        )
        // A score under the threshold always has at least one component under 0.7 (a
        // weighted mean cannot sit below all of its parts); the guard only keeps the
        // card from ever saying nothing about why.
        let reasons = readiness.drivers.map(reasonPhrase)
        guard score > 0, !reasons.isEmpty else { return nil }
        let reasonSentence = reasons.formatted(.list(type: .and)).capitalizedFirstLetter + "."

        let advice: String
        if let next = context.nextSession, next.workoutType.isQualitySession || next.workoutType == .longRun {
            advice = String(
                localized: """
                If your \(next.workoutType.localizedName.lowercased()) is next, run it easy \
                instead or push it back a day. A hard session on a tired body costs more \
                than it builds.
                """,
                comment: "Readiness card advice when the next session is demanding"
            )
        } else {
            advice = String(
                localized: """
                Keep the next run genuinely easy, or take the day off. One easy day now \
                costs far less than a flat week later.
                """,
                comment: "Readiness card advice when the next session is easy or none"
            )
        }

        return SmartCoachCard(
            kind: .readiness,
            title: String(localized: "Recovery is running low", comment: "Coach card title"),
            message: "\(reasonSentence) \(advice)",
            glance: String(
                localized: "Recovery is low. Keep the next run easy.",
                comment: "Short coach tip for low readiness"
            ),
            tone: .caution,
            score: score,
            derivation: CoachNutrition.derivation(
                [String(
                    localized: "Readiness \(readiness.score)/100",
                    comment: "Derivation fragment with the readiness score"
                )] + readiness.components.map(derivationFragment)
            ),
            // Last night's readings describe one day. Anchored to the reading, not to
            // when the card was built, so a rebuild does not push the expiry out.
            expiresAt: readiness.validUntil
        )
    }

    /// "your heart-rate variability is 22% under your usual" — one clause per driver.
    private static func reasonPhrase(_ component: RecoveryReadiness.Component) -> String {
        switch component.kind {
        case .heartRateVariability:
            let percent = Int(abs(component.reading).rounded())
            return String(
                localized: "your heart-rate variability is \(percent)% under your usual",
                comment: "Readiness reason: HRV below the runner's four-week mean"
            )
        case .restingHeartRate:
            let bpm = Int(component.reading.rounded())
            return String(
                localized: "your resting heart rate is \(bpm) bpm above your usual",
                comment: "Readiness reason: resting heart rate above the runner's four-week mean"
            )
        case .sleep:
            return String(
                localized: "you slept \(hoursAndMinutes(component.reading))",
                comment: "Readiness reason: a short night"
            )
        case .load:
            return String(
                localized: "the last seven days were \(ratioString(component.reading)) your usual week",
                comment: "Readiness reason: recent running time well above the monthly norm"
            )
        }
    }

    /// "HRV −22%", "resting HR +6 bpm", "7.2 h sleep", "load 1.1×".
    private static func derivationFragment(_ component: RecoveryReadiness.Component) -> String {
        switch component.kind {
        case .heartRateVariability:
            return String(
                localized: "HRV \(signed(Int(component.reading.rounded())))%",
                comment: "Derivation fragment: HRV change against baseline"
            )
        case .restingHeartRate:
            return String(
                localized: "resting HR \(signed(Int(component.reading.rounded()))) bpm",
                comment: "Derivation fragment: resting heart rate change against baseline"
            )
        case .sleep:
            return String(
                localized: "\(String(format: "%.1f", component.reading)) h sleep",
                comment: "Derivation fragment: hours slept"
            )
        case .load:
            return String(
                localized: "load \(ratioString(component.reading))",
                comment: "Derivation fragment: seven-day vs four-week running time"
            )
        }
    }

    /// "5 h 20 min".
    private static func hoursAndMinutes(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let wholeHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0
            ? String(localized: "\(wholeHours) h", comment: "Sleep duration, whole hours")
            : String(localized: "\(wholeHours) h \(minutes) min", comment: "Sleep duration, hours and minutes")
    }

    /// "1.5×".
    private static func ratioString(_ ratio: Double) -> String {
        "\(String(format: "%.1f", ratio))×"
    }

    /// "+6", "−22" — with a real minus sign, and a plus so a rise reads as one.
    private static func signed(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\u{2212}\(abs(value))"
    }
}

private extension String {
    /// The list formatter lowercases nothing and capitalises nothing, and every reason
    /// clause starts lowercase so it can sit mid-sentence. This lifts the first one.
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
