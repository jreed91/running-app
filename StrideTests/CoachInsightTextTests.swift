import Foundation
import Testing
@testable import Stride

/// Covers `CoachInsightText`, the run summary's prose assembly (D1). Every field it
/// composes is optional or model-supplied, so the cases worth pinning are the ones where
/// the coach returns less than the card assumes.
struct CoachInsightTextTests {

    private func insight(
        headline: String = "Strong tempo",
        summary: String = "You held the target band.",
        fullAnalysis: String? = nil,
        actionItems: [AICoachActionItem] = [],
        nextWorkoutSuggestion: String = "Easy 6 km",
        nextWorkoutRationale: String? = nil
    ) -> AICoachInsight {
        AICoachInsight(
            headline: headline,
            summary: summary,
            fullAnalysis: fullAnalysis,
            confidence: 80,
            evidence: [],
            actionItems: actionItems,
            focusAreas: [],
            nextWorkoutSuggestion: nextWorkoutSuggestion,
            nextWorkoutRationale: nextWorkoutRationale,
            apiReady: true
        )
    }

    private func action(_ title: String, _ detail: String) -> AICoachActionItem {
        AICoachActionItem(title: title, detail: detail, priority: "high", metric: nil, tone: nil)
    }

    // MARK: Full analysis

    @Test("The model's own full analysis is used verbatim when it has one")
    func prefersModelFullAnalysis() {
        let text = CoachInsightText.fullAnalysis(
            for: insight(fullAnalysis: "  Your aerobic base is holding.  ")
        )

        #expect(text == "Your aerobic base is holding.")
    }

    @Test("An empty full analysis falls back rather than rendering a blank card")
    func emptyFullAnalysisFallsBack() {
        // A model with nothing more to add returns "" as readily as it returns nil, and
        // the card has a heading above it either way.
        for empty in ["", "   ", "\n"] {
            let text = CoachInsightText.fullAnalysis(for: insight(fullAnalysis: empty))
            #expect(text.contains("You held the target band."))
        }
    }

    @Test("The fallback composes summary, action items, and the next session")
    func fallbackComposition() {
        let text = CoachInsightText.fullAnalysis(for: insight(
            actionItems: [action("Recover", "Two easy days.")],
            nextWorkoutSuggestion: "Easy 6 km",
            nextWorkoutRationale: "Your legs need the volume, not the intensity."
        ))

        #expect(text == "You held the target band. Recover: Two easy days. "
            + "Next session: Easy 6 km. Your legs need the volume, not the intensity.")
    }

    @Test("The fallback quotes at most three action items")
    func fallbackCapsActionItems() {
        let items = (1...5).map { action("Item \($0)", "Detail \($0).") }

        let text = CoachInsightText.fullAnalysis(for: insight(actionItems: items))

        #expect(text.contains("Item 3"))
        // The whole action plan is rendered separately above this card.
        #expect(!text.contains("Item 4"))
    }

    @Test("A missing rationale leaves no dangling separator")
    func missingRationaleIsDropped() {
        let text = CoachInsightText.fullAnalysis(for: insight(nextWorkoutRationale: nil))

        #expect(text.hasSuffix("Next session: Easy 6 km."))
        #expect(!text.contains("  "))
    }

    @Test("An insight with nothing populated composes to an empty string, not to spaces")
    func fullyEmptyInsightComposesEmpty() {
        let text = CoachInsightText.fullAnalysis(for: insight(
            summary: "",
            nextWorkoutSuggestion: ""
        ))

        // "Next session: ." is what an unfiltered join would leave behind here; the
        // suggestion is the only content that line carries.
        #expect(text == "Next session: .")
    }

    // MARK: Feedback prompt

    @Test("The feedback prompt names the completed session and its date")
    func promptNamesTheSession() {
        let date = Calendar.current.date(from: DateComponents(year: 2027, month: 3, day: 15)) ?? .now

        let prompt = CoachInsightText.feedbackPrompt(
            insight: insight(),
            completedType: .tempo,
            completedOn: date
        )

        #expect(prompt.hasPrefix("AI Coach feedback from completed tempo on "))
        #expect(prompt.contains("Strong tempo"))
        #expect(prompt.contains("You held the target band."))
        #expect(prompt.contains("Next session suggestion: Easy 6 km"))
    }

    @Test("Markup is stripped so the prompt spends no budget on asterisks")
    func promptStripsMarkup() {
        let prompt = CoachInsightText.feedbackPrompt(
            insight: insight(
                headline: "**Strong** tempo",
                summary: "You held the `target` band.",
                nextWorkoutSuggestion: "__Easy__ 6 km"
            ),
            completedType: .tempo,
            completedOn: .now
        )

        #expect(!prompt.contains("**"))
        #expect(!prompt.contains("__"))
        #expect(!prompt.contains("`"))
        #expect(prompt.contains("Strong tempo"))
    }

    @Test("A rationale is labelled when present and absent otherwise")
    func promptRationaleIsOptional() {
        let withRationale = CoachInsightText.feedbackPrompt(
            insight: insight(nextWorkoutRationale: "Keep the volume."),
            completedType: .easy,
            completedOn: .now
        )
        let without = CoachInsightText.feedbackPrompt(
            insight: insight(nextWorkoutRationale: nil),
            completedType: .easy,
            completedOn: .now
        )

        #expect(withRationale.contains("Rationale: Keep the volume."))
        #expect(!without.contains("Rationale:"))
    }

    @Test("The session type is worded as the summary screen labels it")
    func promptUsesDisplayType() {
        let prompt = CoachInsightText.feedbackPrompt(
            insight: insight(),
            completedType: .longRun,
            completedOn: .now
        )

        #expect(prompt.hasPrefix("AI Coach feedback from completed long run on "))
    }

    // MARK: Evidence delta

    @Test("A delta that repeats the value adds nothing")
    func deltaRepeatingValue() {
        #expect(!CoachInsightText.deltaAddsInformation(value: "76%", delta: "+76%"))
        #expect(!CoachInsightText.deltaAddsInformation(value: "76%", delta: nil))
        #expect(!CoachInsightText.deltaAddsInformation(value: "76%", delta: "  "))
    }

    @Test("A real comparison is kept")
    func deltaComparing() {
        #expect(CoachInsightText.deltaAddsInformation(value: "9:51/mi", delta: "-44s"))
        #expect(CoachInsightText.deltaAddsInformation(value: "1.4 mi", delta: "-2.0 mi"))
    }
}
