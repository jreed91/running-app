import Foundation

// MARK: - GuidedStepAnnouncement

/// The sentences a runner *hears* while a structured workout steps them through its reps.
///
/// The guided banner (A4) says what the current step is and how much of it is left, and
/// the HUD thumps a heavy haptic when the step changes — but a haptic cannot say whether
/// the thing that just started is the rep or the recovery, and the banner is no help to
/// a phone in an armband. Every competing coach talks the runner through the session;
/// until this, Stride's voice only ever read out splits.
///
/// Two kinds of cue, both pure and separate from the speaking itself (``RunVoiceCoach``)
/// so the wording is unit-testable, the way ``SplitAnnouncement`` is:
///
/// - ``stepStart(_:unit:)`` — what just started and what to do: "Rep 3 of 6. 800 metres
///   at 3:55 minutes per kilometre. Go."
/// - ``headsUp(for:from:to:unit:)`` — one line near the end of a rep or recovery, so the
///   change does not arrive as a surprise: "10 seconds left." / "100 metres. Get ready."
///
/// Warm-up and cool-down get a start cue but never a heads-up: they are easy running, and
/// a countdown into the first rep is what the warm-up's own heads-up would be for — the
/// start cue for rep 1 already says "Go".
enum GuidedStepAnnouncement {

    /// How long before a time-based step ends its heads-up is spoken, in seconds.
    static let headsUpSeconds: Double = 10

    /// Steps shorter than this get no time heads-up: on a 20-second stride the warning
    /// would land halfway through, and the start cue has only just finished.
    static let minimumSecondsForHeadsUp: Double = 30

    /// How far before a distance-based step ends its heads-up is spoken, in metres, per
    /// display unit — 100 m for a metric runner, 100 yd for an imperial one, so the
    /// number spoken is a round one in the unit they think in.
    static func headsUpMeters(unit: UnitPreference) -> Double {
        switch unit {
        case .metric:   return 100
        case .imperial: return 100 * yardInMeters
        }
    }

    // MARK: Step start

    /// The announcement for a step that has just begun.
    static func stepStart(_ step: GuidedStep, unit: UnitPreference) -> String {
        var sentences: [String] = []

        switch step.kind {
        case .warmup:
            sentences.append(String(localized: "Warm-up.", comment: "Spoken when a guided workout's warm-up begins"))
        case .work:
            sentences.append(workTitle(step))
        case .recovery:
            sentences.append(String(localized: "Recover.", comment: "Spoken when a recovery between guided reps begins"))
        case .cooldown:
            sentences.append(String(localized: "Main set done. Cool-down.", comment: "Spoken when a guided workout's cool-down begins"))
        }

        sentences.append(targetSentence(step, unit: unit))

        if step.kind == .work {
            sentences.append(String(localized: "Go.", comment: "Spoken at the end of the cue that starts a guided rep"))
        }

        return sentences.joined(separator: " ")
    }

    /// "Rep 3 of 6." / "Last rep, 6 of 6." / "Tempo." — the work step named the way a
    /// coach at the track would call it.
    private static func workTitle(_ step: GuidedStep) -> String {
        if let index = step.repIndex, let count = step.repCount {
            if index == count {
                return String(localized: "Last rep, \(index) of \(count).", comment: "Spoken when the final rep of a guided set begins")
            }
            return String(localized: "Rep \(index) of \(count).", comment: "Spoken when a rep of a guided set begins")
        }
        // A single-rep set (a tempo block) has no rep count to call; its label is what
        // the banner shows, so it is what the runner hears.
        return step.label.hasSuffix(".") ? step.label : step.label + "."
    }

    /// What the step asks for: its distance or duration, and for a rep its pace.
    ///
    /// Only work steps carry their pace out loud. The warm-up and cool-down segments do
    /// hold one — the easy band's slow edge, as a ceiling — but "a kilometre at no faster
    /// than 6:10" is over-coaching an easy jog, and a recovery never prescribes one.
    private static func targetSentence(_ step: GuidedStep, unit: UnitPreference) -> String {
        let amount: String
        switch step.target {
        case .distance(let meters):
            amount = spokenDistance(meters: meters, unit: unit)
        case .time(let seconds):
            amount = spokenDuration(seconds: seconds)
        case .open:
            return step.kind == .recovery
                ? String(localized: "Tap Next when you're ready.", comment: "Spoken for a guided recovery with no set length")
                : String(localized: "Tap Next when you're done.", comment: "Spoken for a guided step with no set length")
        }

        if step.kind == .work, let pace = step.targetPaceSecondsPerKm, pace > 0, pace.isFinite {
            let spokenPace = SpokenMetric.spoken(measurement: pace.paceString(unit: unit))
            return String(localized: "\(amount) at \(spokenPace).", comment: "Spoken target for a guided rep: its length, then its pace")
        }
        return amount + "."
    }

    // MARK: Heads-up

    /// The heads-up to speak on this tick, or `nil` when there is none.
    ///
    /// Fires on the *crossing*: the tick whose remaining amount first drops to or below
    /// the threshold, given the one before it was still above. Deciding on the crossing
    /// rather than on "is it under the threshold now" is what lets the caller hold no
    /// "already said it" flag; ``RunSpokenCues`` only keeps the previous tick's reading.
    ///
    /// - Parameters:
    ///   - step: the step both progress readings belong to. The caller must not pass
    ///     readings from either side of a step change: remaining jumps back up there,
    ///     which is never a downward crossing, but a reading from the previous step's
    ///     tail could be.
    ///   - old: the progress on the previous tick.
    ///   - new: the progress now.
    static func headsUp(
        for step: GuidedStep,
        from old: GuidedStepProgress,
        to new: GuidedStepProgress,
        unit: UnitPreference
    ) -> String? {
        guard step.kind == .work || step.kind == .recovery else { return nil }

        switch step.target {
        case .time(let total):
            guard total >= minimumSecondsForHeadsUp,
                  let before = old.remainingSeconds,
                  let now = new.remainingSeconds,
                  before > headsUpSeconds, now <= headsUpSeconds, now > 0 else { return nil }
            let amount = spokenDuration(seconds: headsUpSeconds)
            return step.kind == .recovery
                ? String(localized: "\(amount). Get ready.", comment: "Spoken shortly before a guided recovery ends")
                : String(localized: "\(amount) left.", comment: "Spoken shortly before a timed guided rep ends")

        case .distance(let total):
            let threshold = headsUpMeters(unit: unit)
            // Twice the threshold, so a 100 m stride is never told "100 metres to go"
            // as it starts.
            guard total >= threshold * 2,
                  let before = old.remainingDistanceMeters,
                  let now = new.remainingDistanceMeters,
                  before > threshold, now <= threshold, now > 0 else { return nil }
            let amount = spokenDistance(meters: threshold, unit: unit)
            return step.kind == .recovery
                ? String(localized: "\(amount). Get ready.", comment: "Spoken shortly before a guided recovery ends")
                : String(localized: "\(amount) to go.", comment: "Spoken shortly before a guided rep's distance is reached")

        case .open:
            return nil
        }
    }

    // MARK: Spoken amounts

    private static let yardInMeters = 0.9144
    private static let mileInMeters = 1_609.344

    /// A step's distance as a runner would say it.
    ///
    /// Short distances are whole metres or yards, not "0.8 kilometres": reps are named
    /// "800s", and the plan's own set labels (`TrainingPlanService.shortDistanceString`)
    /// switch to yards below a mile for the same reason. Longer ones are kilometres or
    /// miles with at most two decimals and no trailing zeros, so a warm-up is "1
    /// kilometre" rather than "1.0 kilometres".
    static func spokenDistance(meters: Double, unit: UnitPreference) -> String {
        switch unit {
        case .metric:
            if meters < 1_000 {
                let whole = Int((meters / 10).rounded()) * 10
                return String(localized: "\(whole) metres", comment: "Spoken distance under a kilometre")
            }
            let km = meters / 1_000
            if abs(km - 1) < 0.005 {
                return String(localized: "1 kilometre", comment: "Spoken distance of exactly one kilometre")
            }
            return String(localized: "\(trimmed(km)) kilometres", comment: "Spoken distance in kilometres")
        case .imperial:
            let miles = meters / mileInMeters
            // Just under a mile still reads as a mile: a 1,600 m rep is a "mile repeat".
            if abs(miles - 1) < 0.01 {
                return String(localized: "1 mile", comment: "Spoken distance of exactly one mile")
            }
            if miles < 1 {
                let whole = Int((meters / yardInMeters / 10).rounded()) * 10
                return String(localized: "\(whole) yards", comment: "Spoken distance under a mile")
            }
            return String(localized: "\(trimmed(miles)) miles", comment: "Spoken distance in miles")
        }
    }

    /// A duration as a runner would say it: "90 seconds", "3 minutes", "2 minutes 30
    /// seconds" — never "1:30", which a synthesiser reads as a time of day.
    ///
    /// Anything under two minutes stays in seconds, because that is how recoveries are
    /// prescribed and called ("90 seconds", not "1 minute 30").
    static func spokenDuration(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 120 {
            return total == 1
                ? String(localized: "1 second", comment: "Spoken duration of one second")
                : String(localized: "\(total) seconds", comment: "Spoken duration in seconds")
        }
        let minutes = total / 60
        let remainder = total % 60
        let minutePart = String(localized: "\(minutes) minutes", comment: "Spoken whole minutes of a duration")
        guard remainder > 0 else { return minutePart }
        let secondPart = remainder == 1
            ? String(localized: "1 second", comment: "Spoken duration of one second")
            : String(localized: "\(remainder) seconds", comment: "Spoken duration in seconds")
        return minutePart + " " + secondPart
    }

    /// Up to two decimals, trailing zeros dropped: 1.5 → "1.5", 2 → "2", 1.25 → "1.25".
    private static func trimmed(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
