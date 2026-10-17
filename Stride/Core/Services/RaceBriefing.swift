import Foundation

// MARK: - Model output

/// The race briefing as Apple's model wrote it, before anything has checked it. Plain
/// strings so `OnDeviceCoachGenerating` can hand it across without `FoundationModels`.
struct RaceBriefingDraft: Sendable, Equatable {
    let headline: String
    let pacing: String
    let beforeTheRace: String
}

/// A model-written briefing that passed ``RaceBriefing/validated(_:for:unit:)``, bound to
/// the facts it was written from.
struct RaceBriefingWording: Codable, Sendable, Equatable {
    let headline: String
    let pacing: String
    let beforeTheRace: String
    /// ``RaceBriefing/prompt(for:unit:)`` at the time of writing.
    let source: String
}

// MARK: - RaceBriefing

/// The race hub's "race plan" card: how to run the race, in a coach's words, written by
/// Apple Intelligence from the goal ladder, the prediction and the taper that
/// ``RaceDayPlan`` already computed.
///
/// The same split as `WeekReview` and `CoachTipRewriter`: the app owns every number, the
/// model only writes the words, and a draft carrying any number the facts do not is
/// dropped. Unlike those, there is no plain copy to fall back to — every figure the
/// briefing could quote is already on the hub, so without a checked wording the card is
/// simply not drawn.
///
/// Pure: the generation itself is `AICoachService.writeRaceBriefing(for:unit:provider:)`.
enum RaceBriefing {

    static let maximumHeadlineLength = 60
    static let maximumPacingLength = 420
    static let maximumBeforeLength = 200

    /// Whether the hub should ask for a briefing at all: only for a race still to come,
    /// and only with a goal time to plan against.
    static func applies(to plan: RaceDayPlan) -> Bool {
        if case .finished = plan.phase { return false }
        return plan.result == nil && plan.goal != nil
    }

    static let instructions = """
    You are Stride's running coach, writing a short race plan for a runner's goal race.

    The app has already worked out the runner's goal times, the paces they imply, what \
    recent training predicts, and where the training plan stands. Write like a coach \
    talking to this runner: say "you", use everyday words, keep each sentence to one idea, \
    and be calm and practical.

    Say which goal to aim for given the prediction, how to pace the start, middle and \
    finish, and what to do in the time left before the race. If the prediction is slower \
    than the A goal, be honest that the A goal is a stretch and suggest starting at the B \
    goal's pace.

    Use only the facts given. Copy any time, pace, distance or unit exactly as it is \
    written, and write no other numbers: do not add, subtract, round or convert them. Do \
    not invent splits, weather, courses or nutrition amounts.

    No lists, headings or emoji. Give no medical advice, and never mention that you are \
    an AI.
    """

    /// The facts as the model reads them, one per line, in English like every coach
    /// prompt. Doubles as the key a wording is bound to (``RaceBriefingWording/source``).
    static func prompt(for plan: RaceDayPlan, unit: UnitPreference) -> String {
        var lines: [String] = []
        lines.append("Race: \(plan.raceName)")
        lines.append("Distance: \(plan.distanceMeters.distanceString(unit: unit))")
        lines.append("When: \(whenLine(plan.phase))")

        for goal in plan.goals {
            let name = goal.tier.rawValue.uppercased()
            lines.append(
                "\(name) goal: \(goal.finishSeconds.durationString) at \(goal.paceSecondsPerKm.paceString(unit: unit))"
            )
        }

        if let predicted = plan.predictedFinishSeconds {
            lines.append("Recent training predicts: \(predicted.durationString)")
            if let goal = plan.goal {
                let gap = comparison(predicted: predicted, goal: goal.finishSeconds)
                lines.append("Prediction against the A goal: \(gap)")
            }
        } else {
            lines.append("Recent training predicts: not enough recent hard sessions to say")
        }

        if let taper = plan.taper {
            lines.append("Plan: \(taper.phase.displayName) phase, week \(taper.weekNumber) of \(taper.totalWeeks)")
            lines.append("This week's planned distance: \(taper.plannedKm.distanceStringFromKm(unit: unit))")
            if taper.reductionFromPeak >= 0.05 {
                let percent = Int((taper.reductionFromPeak * 100).rounded())
                lines.append("Below the biggest week of the plan by: \(percent)%")
            }
        }

        return """
        Write a race plan for this race.

        \(lines.joined(separator: "\n"))
        """
    }

    private static func whenLine(_ phase: RacePhase) -> String {
        switch phase {
        case .building(let days):  return "\(days) days away"
        case .raceWeek(let days):  return days == 1 ? "tomorrow" : "race week, \(days) days away"
        case .raceDay:             return "today"
        case .finished:            return "already run"
        }
    }

    /// The gap in words with its size precomputed, so the model never has to subtract.
    /// Within a minute either way is "about the same": a prediction is not that precise.
    private static func comparison(predicted: TimeInterval, goal: TimeInterval) -> String {
        let gap = predicted - goal
        guard abs(gap) >= 60 else { return "about the same" }
        return gap > 0
            ? "\(gap.durationString) slower than the A goal"
            : "\((-gap).durationString) faster than the A goal"
    }

    // MARK: Validation

    /// The draft when it is safe to show, else nil: no blank or overlong field, and no
    /// number that the prompt does not carry (compared by value, as `WeekReview` does).
    static func validated(
        _ draft: RaceBriefingDraft,
        for plan: RaceDayPlan,
        unit: UnitPreference
    ) -> RaceBriefingWording? {
        let headline = draft.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let pacing = draft.pacing.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = draft.beforeTheRace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty, headline.count <= maximumHeadlineLength,
              !pacing.isEmpty, pacing.count <= maximumPacingLength,
              !before.isEmpty, before.count <= maximumBeforeLength else { return nil }

        let source = prompt(for: plan, unit: unit)
        let allowed = WeekReview.normalizedNumbers(in: source)
        let written = WeekReview.normalizedNumbers(in: headline)
            .union(WeekReview.normalizedNumbers(in: pacing))
            .union(WeekReview.normalizedNumbers(in: before))
        guard written.isSubset(of: allowed) else { return nil }

        return RaceBriefingWording(headline: headline, pacing: pacing, beforeTheRace: before, source: source)
    }
}

// MARK: - RaceBriefingStore

/// The last accepted briefing, kept on this device so reopening the hub on an unchanged
/// day does not spend another Private Cloud Compute request. Local `UserDefaults`, never
/// iCloud, holding only the one wording, keyed by its facts.
enum RaceBriefingStore {
    private static let key = "raceHub.briefing.lastWording"

    static func load(from defaults: UserDefaults = .standard) -> RaceBriefingWording? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RaceBriefingWording.self, from: data)
    }

    static func save(_ wording: RaceBriefingWording, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(wording) else { return }
        defaults.set(data, forKey: key)
    }
}
