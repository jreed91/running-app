import Foundation

/// How the coach pitches its words to the runner's experience.
///
/// The coach used to write one way for everyone: plain words, and every training term
/// explained the first time it came up. That read as hand-holding to an experienced
/// runner, and still used words like "threshold" and "zone 4" that a new runner had to
/// stop and decode. The runner's own answer to "how much do you run?" (`FitnessLevel`,
/// asked in onboarding and changeable in Settings) now picks the voice.
///
/// Only the wording moves with the level. What the coach judges — the plan's pace, the
/// usual for this kind of run, the verdict — is the same for every runner, so the rules
/// for that stay in the shared instructions and this paragraph is appended after them.
enum CoachVoice: Equatable, Sendable {
    /// New to running, or coming back. No jargon at all.
    case newRunner
    /// Runs regularly. Everyday words, and a training term explained the first time.
    /// This is how the coach wrote for everyone before, and the voice when there is
    /// no profile.
    case recreational
    /// Trains seriously. Standard terms used freely, exact figures.
    case experienced
    /// Races to a goal. As `.experienced`, framed around the goal race.
    case competitive

    init(_ level: FitnessLevel?) {
        switch level {
        case .beginner:            self = .newRunner
        case .intermediate, nil:   self = .recreational
        case .advanced:            self = .experienced
        case .competitive:         self = .competitive
        }
    }

    /// The paragraph appended to the chat, run read and adaptation instructions.
    var guidance: String {
        switch self {
        case .newRunner:
            return """
            Who you are talking to: a runner who is new to running, or coming back to it. \
            Write for someone who has never trained to a plan. Use everyday words only, \
            with no training jargon: say "an easy pace you could chat at" rather than \
            "zone 2" or "aerobic", "a steady push you could hold for about an hour" \
            rather than "threshold" or "tempo pace", and "your heart rate" rather than \
            "HR" or "bpm". If the session itself has a name like tempo or intervals, say \
            what it means in a few words. Name a heart-rate zone by how it feels, not by \
            its number. For example, not "67% at threshold or harder, cadence 153 spm" \
            but "two-thirds of the run was at a hard effort, about 153 steps a minute". Keep the numbers in your sentences few, and say what each one \
            means for them. How the run felt and turning up again matter more than pace \
            at this stage, so say when they did the right thing. An uneven pace, a slow \
            finish or a walk break is normal for a new runner, not a fault to fix. Be \
            warm and specific; empty praise like "great job" on its own is not enough.
            """
        case .recreational:
            return """
            Who you are talking to: a runner who runs regularly but is not a specialist. \
            Use everyday words, and prefer an everyday word to a training term whenever \
            one will do: "a hard effort" rather than "threshold", "steps a minute" rather \
            than "cadence" or "spm". When a training term is the right word, explain it in \
            a few words the first time, for example "threshold pace, the effort you could \
            hold for about an hour". Name a heart-rate zone by what it feels like as well \
            as its number ("zone 4, comfortably hard"). Spell out what a number means \
            rather than leaving it to speak for itself. For example, not "67% at \
            threshold or harder" but "two-thirds of the run was at a hard effort, zone 4 \
            or above".
            """
        case .experienced:
            return """
            Who you are talking to: an experienced runner who trains seriously. Talk to \
            them as a coach talks to a seasoned athlete. Use standard training terms \
            (threshold, VO2 max, aerobic decoupling, cardiac drift, cadence, negative \
            split, zone numbers) without defining them. Be precise: give the exact pace, \
            split or heart-rate figure rather than rounding it into words. Skip the \
            basics they already know, such as why easy runs should be easy; spend the \
            words on what is specific to this session and what to change. Be direct \
            about what went wrong. Short sentences still beat long ones.
            """
        case .competitive:
            return """
            Who you are talking to: a competitive runner who races to a goal. Talk to \
            them as a coach talks to a racer. Use standard training terms (threshold, \
            VO2 max, aerobic decoupling, cardiac drift, cadence, negative split, zone \
            numbers) without defining them. Be precise: give the exact pace, split or \
            heart-rate figure rather than rounding it into words. Skip the basics they \
            already know; spend the words on what this session says about their goal \
            race and the small changes that would move it. Be direct about what went \
            wrong. Short sentences still beat long ones.
            """
        }
    }

    /// Whether the app's own lines in the prompt (zone names, the hard-effort share, the
    /// cadence note) are written without training terms. The model copies those lines
    /// almost word for word, so a plain voice over jargon-laden facts still came out
    /// as "67% was at threshold or harder".
    var usesPlainFacts: Bool {
        self == .newRunner || self == .recreational
    }

    /// `base` with this voice's paragraph placed right after its opening paragraph.
    ///
    /// Up front rather than at the end: appended after several paragraphs of judging
    /// rules, the on-device model gave it little weight. The opening paragraph (the role)
    /// still comes first.
    func instructions(_ base: String) -> String {
        guard let split = base.range(of: "\n\n") else { return guidance + "\n\n" + base }
        let opening = String(base[..<split.lowerBound])
        let rest = String(base[split.upperBound...])
        return opening + "\n\n" + guidance + "\n\n" + rest
    }

    /// A tile's label or value, or an action's metric, worded for this runner.
    ///
    /// The tiles fit about ten characters, so the model reaches for "spm" and "Threshold
    /// time" even when told to write plainly. For a plain voice those two are swapped
    /// for everyday words here; anything else is left as written.
    func tileText(_ text: String) -> String {
        guard usesPlainFacts else { return text }
        var result = text.replacingOccurrences(
            of: #"\bspm\b"#,
            with: "steps/min",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: #"\bthreshold\b"#,
            with: "hard effort",
            options: [.regularExpression, .caseInsensitive]
        )
        if let first = result.first, text.first?.isUppercase == true {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }
}
