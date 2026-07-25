import Foundation

// MARK: - CoachInsightText

/// Composes prose out of an ``AICoachInsight``: the full-analysis body the run summary
/// renders, and the feedback prompt sent back to the coach when the runner asks for
/// their next session to be rewritten.
///
/// Both ran inline in `RunSummaryView` (D1). They are string assembly with real rules in
/// them — which fields are optional, what happens when the model returns an empty one,
/// how many action items are worth quoting — and a view body is the one place those
/// rules cannot be checked.
enum CoachInsightText {

    /// How many action items the fallback analysis quotes before it stops.
    ///
    /// The fallback exists to stand in for a missing `fullAnalysis`, not to reproduce
    /// the whole action plan, which is rendered separately just above it.
    static let fallbackActionItemLimit = 3

    // MARK: Full analysis

    /// The body of the "Full analysis" card.
    ///
    /// Prefers the model's own `fullAnalysis`. When that is absent — or present but
    /// empty, which a model that has decided it has nothing more to add will happily
    /// return — one is composed from the fields that are always populated, so the card
    /// never renders blank under its heading.
    static func fullAnalysis(for insight: AICoachInsight) -> String {
        if let fullAnalysis = insight.fullAnalysis?.nonEmptyTrimmed {
            return fullAnalysis
        }

        let actionSummary = insight.actionItems
            .prefix(fallbackActionItemLimit)
            .map { "\($0.title): \($0.detail)" }
            .joined(separator: " ")

        let nextWorkout = joined([
            "Next session: \(insight.nextWorkoutSuggestion).",
            insight.nextWorkoutRationale
        ])

        return joined([insight.summary, actionSummary, nextWorkout])
    }

    // MARK: Feedback prompt

    /// The coach's own reading of a finished run, handed back to it as plain prompt text
    /// when the runner applies that feedback to their next session.
    ///
    /// Deliberately a `String` rather than a seeded `ScheduledWorkout`: relating an
    /// unmanaged model to a persisted week auto-inserts it, which left a phantom
    /// duplicate in the plan.
    ///
    /// The markup is stripped first. The model wrote this text for a card that renders
    /// `**bold**`, and feeding it back with the asterisks intact spends prompt budget on
    /// punctuation and invites the next response to imitate it.
    ///
    /// - Parameters:
    ///   - insight: The cached insight for the completed run.
    ///   - completedType: The workout type as the summary screen labels it, which is the
    ///     scheduled type when the run fulfilled a plan day.
    ///   - completedOn: The run's date.
    static func feedbackPrompt(
        insight: AICoachInsight,
        completedType: WorkoutType,
        completedOn date: Date
    ) -> String {
        let heading = "AI Coach feedback from completed \(completedType.displayName.lowercased())"
            + " on \(date.formatted(date: .abbreviated, time: .omitted)):"

        return joined([
            heading,
            CoachMarkdown.stripped(insight.headline),
            CoachMarkdown.stripped(insight.summary),
            "Next session suggestion: \(CoachMarkdown.stripped(insight.nextWorkoutSuggestion))",
            insight.nextWorkoutRationale.map { "Rationale: \(CoachMarkdown.stripped($0))" }
        ])
    }

    // MARK: Composition

    /// Trims each part, drops the empty ones, and joins the rest with a single space.
    ///
    /// Every composed field here is optional or model-supplied, so "this one came back
    /// empty" is the ordinary case rather than the exceptional one; without the filter
    /// it surfaces as doubled spaces and dangling colons.
    private static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0?.nonEmptyTrimmed }.joined(separator: " ")
    }
}

private extension String {
    /// The trimmed string, or `nil` when nothing is left of it.
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
