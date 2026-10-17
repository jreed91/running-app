import Foundation

/// The questions offered under "Ask your coach" on a run's coach page, picked from what
/// stood out in that run.
///
/// They were the same three on every run ("Why was my HR so high?" under an easy jog
/// at 130 bpm). Each question here has a reason to be asked about this run, from the
/// app's own numbers rather than a model call, so they are ready the moment the page
/// opens and cost nothing. Pure and Foundation-only.
enum CoachQuestionSuggestions {

    /// How many questions the page shows.
    static let limit = 3

    /// What stood out in the run, as the questions need it.
    struct Signals: Sendable {
        var workoutType: WorkoutType
        /// Share of heart-rate time in zones 4–5, 0...1; `nil` without zone data.
        var hardEffortShare: Double?
        /// Second-half pace minus first-half pace, display-unit seconds; positive is a fade.
        var secondHalfDeltaSeconds: Double?
        /// Actual distance over planned distance; `nil` without a planned distance.
        var planDistanceRatio: Double?
        /// Average pace against the planned range: negative faster, positive slower,
        /// zero inside it; `nil` without a planned pace.
        var planPaceOffsetSeconds: Double?
        var feel: RunFeel?
        /// The next planned run, named for the question ("Thu tempo"); `nil` when none.
        var nextPlannedLabel: String?
    }

    /// A hard share above this on an easy or long run is worth asking about.
    static let hardShareThreshold = 0.20
    /// A second half this many seconds slower is a fade worth asking about.
    static let fadeThresholdSeconds = 10.0
    /// Finishing this much short of the planned distance is worth asking about.
    static let shortDistanceRatio = 0.9
    /// This far off the planned pace range, in seconds, is worth asking about.
    static let paceOffsetThresholdSeconds = 5.0

    /// Up to `limit` questions, most specific first, topped up with general ones.
    static func questions(for signals: Signals) -> [String] {
        var picked: [String] = []
        let isEasyKind = signals.workoutType == .easy || signals.workoutType == .longRun

        if let share = signals.hardEffortShare, share >= hardShareThreshold, isEasyKind {
            picked.append(String(localized: "Why was my heart rate so high?", comment: "Coach question chip"))
        }
        if let offset = signals.planPaceOffsetSeconds, abs(offset) >= paceOffsetThresholdSeconds {
            picked.append(offset < 0
                ? String(localized: "Was I too fast for the plan?", comment: "Coach question chip")
                : String(localized: "Why was I slower than planned?", comment: "Coach question chip"))
        }
        if let ratio = signals.planDistanceRatio, ratio < shortDistanceRatio {
            picked.append(String(localized: "Is it OK that I cut it short?", comment: "Coach question chip"))
        }
        if let fade = signals.secondHalfDeltaSeconds, fade >= fadeThresholdSeconds {
            picked.append(String(localized: "Why did I slow down at the end?", comment: "Coach question chip"))
        } else if let fade = signals.secondHalfDeltaSeconds, fade <= -fadeThresholdSeconds {
            picked.append(String(localized: "How do I keep finishing strong?", comment: "Coach question chip"))
        }
        if let feel = signals.feel, feel.rawValue >= RunFeel.hard.rawValue, isEasyKind {
            picked.append(String(localized: "Why did this feel so hard?", comment: "Coach question chip"))
        }
        if let next = signals.nextPlannedLabel {
            picked.append(String(
                localized: "Should I change \(next)?",
                comment: "Coach question chip; the argument names the next planned run, e.g. Thu tempo"
            ))
        }

        let general = [
            String(localized: "Should I rest tomorrow?", comment: "Coach question chip"),
            String(localized: "How does this compare to last week?", comment: "Coach question chip")
        ]
        for question in general where picked.count < limit {
            picked.append(question)
        }
        return Array(picked.prefix(limit))
    }
}
