import Foundation

/// The runner's own answer to "how did that feel?", given after a run.
///
/// The app measures pace, heart rate and splits, but none of them says whether a run
/// *felt* the way it was meant to — and phone-only runs have no heart rate at all. An easy
/// run that felt hard is the earliest fatigue signal a runner has, and a tempo that felt
/// easy is the plainest sign its paces are soft. This is that signal, stored on the run
/// and read by the coach and by plan adaptation (see `RunFeelSignal`).
///
/// Five steps rather than a 1–10 RPE scale: a runner answers it one-handed, still out of
/// breath, and five named choices are quicker to tell apart than ten numbers. The raw
/// values are the scale position and are what is persisted, so they must never be
/// renumbered.
enum RunFeel: Int, CaseIterable, Codable, Sendable, Identifiable {
    case veryEasy = 1
    case easy = 2
    case moderate = 3
    case hard = 4
    case veryHard = 5

    var id: Int { rawValue }

    var localizedName: String {
        switch self {
        case .veryEasy: return String(localized: "Very easy", comment: "How a run felt, lowest of five")
        case .easy:     return String(localized: "Easy", comment: "How a run felt, second of five")
        case .moderate: return String(localized: "Moderate", comment: "How a run felt, middle of five")
        case .hard:     return String(localized: "Hard", comment: "How a run felt, fourth of five")
        case .veryHard: return String(localized: "Very hard", comment: "How a run felt, highest of five")
        }
    }

    /// English form for coach prompts, which are written in English whatever the app's
    /// language — the same reason prompts use `displayName` rather than `localizedName`.
    var promptName: String {
        switch self {
        case .veryEasy: return "very easy"
        case .easy:     return "easy"
        case .moderate: return "moderate"
        case .hard:     return "hard"
        case .veryHard: return "very hard"
        }
    }

    /// The rating as the coach reads it, e.g. "hard (4 of 5)".
    var promptDescription: String {
        "\(promptName) (\(rawValue) of 5)"
    }
}
