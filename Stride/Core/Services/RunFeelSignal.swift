import Foundation

/// What a runner's "how did that feel?" ratings (`RunFeel`) say about their training.
///
/// The rating on its own is a number; it only means something against what the session
/// was *meant* to feel like. An easy run rated hard is a warning, a tempo rated hard is the
/// workout doing its job. This type holds that one mapping, so the per-run coach read, the
/// coach chat and plan adaptation all judge a rating the same way. Pure Swift, no UI and no
/// persistence, so every threshold is pinned by `RunFeelSignalTests`.
enum RunFeelSignal {

    /// How a rating compared with what the session was meant to feel like.
    enum Mismatch: Equatable, Sendable {
        /// Felt harder than the session called for — the fatigue signal.
        case harderThanIntended
        /// Felt easier than the session called for — the paces may be soft.
        case easierThanIntended
    }

    /// The ratings a session of this type is meant to land in, or `nil` when any answer is
    /// fair game (a race is meant to be as hard as the runner can make it) or the type is
    /// not a run the plan prescribes by effort.
    static func expectedRange(for type: WorkoutType) -> ClosedRange<Int>? {
        switch type {
        // "Conversational" is the whole prescription for both.
        case .easy, .longRun: return RunFeel.veryEasy.rawValue...RunFeel.moderate.rawValue
        // Comfortably hard: an all-out tempo was run as a race, an easy one was run slow.
        case .tempo: return RunFeel.moderate.rawValue...RunFeel.hard.rawValue
        // Reps are meant to hurt, so only "easy" stands out.
        case .interval: return RunFeel.moderate.rawValue...RunFeel.veryHard.rawValue
        case .race, .rest, .crossTraining, .strength, .walk: return nil
        }
    }

    /// Whether `feel` sits outside what a `type` session is meant to feel like.
    static func mismatch(feel: RunFeel, type: WorkoutType) -> Mismatch? {
        guard let range = expectedRange(for: type) else { return nil }
        if feel.rawValue > range.upperBound { return .harderThanIntended }
        if feel.rawValue < range.lowerBound { return .easierThanIntended }
        return nil
    }

    // MARK: - One run

    /// A sentence for the coach's summary of a single rated run.
    static func runSentence(feel: RunFeel, type: WorkoutType) -> String {
        let session = type.displayName.lowercased()
        switch mismatch(feel: feel, type: type) {
        case .harderThanIntended:
            return "You rated this \(session) \(feel.promptName), harder than it was meant to feel."
        case .easierThanIntended:
            return "You rated this \(session) \(feel.promptName), easier than it was meant to feel."
        case nil:
            return "You rated this \(session) \(feel.promptName), about what it was meant to feel like."
        }
    }

    /// A focus item for the coach's read of a single rated run, when the rating changes
    /// what the next session should look like.
    static func runFocus(feel: RunFeel, type: WorkoutType) -> String? {
        switch mismatch(feel: feel, type: type) {
        case .harderThanIntended:
            return "Keep the next easy day truly easy — this one felt harder than planned."
        case .easierThanIntended:
            return "This felt easier than planned; the next \(type.displayName.lowercased()) "
                + "can hold the faster end of its range."
        case nil:
            return nil
        }
    }

    /// The suffix a prompt's history row carries when the run was rated, e.g.
    /// `" | felt hard (4 of 5)"`. Empty for an unrated run, so the row reads as before.
    static func historySuffix(for feel: RunFeel?) -> String {
        feel.map { " | felt \($0.promptDescription)" } ?? ""
    }

    // MARK: - The trend

    /// How many of the newest rated runs the trend looks at.
    static let trendWindow = 5
    /// How many of them have to point the same way before it counts as a trend. One
    /// rating is a bad night's sleep; two in five is a pattern worth acting on.
    static let trendThreshold = 2
    /// Ratings older than this say nothing about how the runner is coping now.
    static let trendMaxAgeDays = 21

    /// One rated run, reduced to what the trend needs.
    struct Rating: Equatable, Sendable {
        let date: Date
        let type: WorkoutType
        let feel: RunFeel
    }

    /// A plain-language read of the runner's recent ratings for the plan-adaptation
    /// prompts, or `nil` when there are too few recent ratings to say anything, or they
    /// say nothing unusual. `ratings` may arrive in any order.
    static func trendSentence(_ ratings: [Rating], now: Date = Date()) -> String? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -trendMaxAgeDays, to: now) ?? now
        let recent = ratings
            .filter { $0.date >= cutoff && $0.date <= now }
            .sorted { $0.date > $1.date }
            .prefix(trendWindow)
        guard recent.count >= trendThreshold else { return nil }

        let harder = recent.filter { mismatch(feel: $0.feel, type: $0.type) == .harderThanIntended }
        let easier = recent.filter { mismatch(feel: $0.feel, type: $0.type) == .easierThanIntended }

        var sentences: [String] = []
        if harder.count >= trendThreshold {
            sentences.append(
                "\(harder.count) of the runner's last \(recent.count) rated runs felt harder than they were "
                    + "meant to (\(describe(harder))). Treat this as a sign of fatigue: hold or ease intensity "
                    + "and volume rather than add to them."
            )
        }
        if easier.count >= trendThreshold {
            sentences.append(
                "\(easier.count) of the runner's last \(recent.count) rated runs felt easier than they were "
                    + "meant to (\(describe(easier))). Their target paces may be conservative; firm them up "
                    + "slightly if nothing else argues against it."
            )
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func describe(_ ratings: [Rating]) -> String {
        ratings
            .map { "\($0.type.displayName.lowercased()) rated \($0.feel.promptName)" }
            .joined(separator: ", ")
    }
}

extension RunWorkout {
    /// The session this run was meant to be: the plan day's type when it fulfilled one,
    /// since that is what the runner was asked to do, else the run's own type.
    var intendedWorkoutType: WorkoutType {
        scheduledWorkout?.workoutType ?? workoutType
    }

    /// This run's rating reduced for `RunFeelSignal.trendSentence`, or `nil` when unrated.
    var feelRating: RunFeelSignal.Rating? {
        feel.map { RunFeelSignal.Rating(date: date, type: intendedWorkoutType, feel: $0) }
    }
}
