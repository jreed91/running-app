import Testing
import Foundation
@testable import Stride

struct CoachQuestionSuggestionsTests {

    private func signals(
        _ type: WorkoutType = .easy,
        hard: Double? = nil,
        fade: Double? = nil,
        distanceRatio: Double? = nil,
        paceOffset: Double? = nil,
        feel: RunFeel? = nil,
        next: String? = nil
    ) -> CoachQuestionSuggestions.Signals {
        CoachQuestionSuggestions.Signals(
            workoutType: type,
            hardEffortShare: hard,
            secondHalfDeltaSeconds: fade,
            planDistanceRatio: distanceRatio,
            planPaceOffsetSeconds: paceOffset,
            feel: feel,
            nextPlannedLabel: next
        )
    }

    @Test("A quiet run gets the general questions")
    func quietRun() {
        #expect(CoachQuestionSuggestions.questions(for: signals()) == [
            "Should I rest tomorrow?",
            "How does this compare to last week?"
        ])
    }

    @Test("An easy run spent at threshold, cut short, asks about both first")
    func hardShortEasyRun() {
        let questions = CoachQuestionSuggestions.questions(for: signals(hard: 0.76, distanceRatio: 0.4, paceOffset: -44))

        #expect(questions == [
            "Why was my heart rate so high?",
            "Was I too fast for the plan?",
            "Is it OK that I cut it short?"
        ])
    }

    @Test("Heart rate is not questioned on a run meant to be hard")
    func hardShareOnTempo() {
        let questions = CoachQuestionSuggestions.questions(for: signals(.tempo, hard: 0.8))

        #expect(!questions.contains("Why was my heart rate so high?"))
    }

    @Test("A fade and a strong finish ask different things")
    func fadeAndNegativeSplit() {
        #expect(CoachQuestionSuggestions.questions(for: signals(fade: 15)).first == "Why did I slow down at the end?")
        #expect(CoachQuestionSuggestions.questions(for: signals(fade: -15)).first == "How do I keep finishing strong?")
        #expect(CoachQuestionSuggestions.questions(for: signals(fade: 4)).first == "Should I rest tomorrow?")
    }

    @Test("The next planned run is named, and the list never passes three")
    func nextPlannedRunAndLimit() {
        let questions = CoachQuestionSuggestions.questions(
            for: signals(hard: 0.5, fade: 20, feel: .veryHard, next: "Thu tempo")
        )

        #expect(questions.count == 3)
        #expect(!questions.contains("Should I change Thu tempo?"))

        let withRoom = CoachQuestionSuggestions.questions(for: signals(next: "Thu tempo"))
        #expect(withRoom.first == "Should I change Thu tempo?")
    }
}
