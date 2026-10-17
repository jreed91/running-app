import Foundation
import Testing
@testable import Stride

/// Covers `CoachPromptBudget`: the size estimate a prompt is measured against, and the
/// rule for what it may lose to fit.
///
/// Only the context window itself comes from the model, so everything that can silently
/// produce a wrong answer — an estimate that undershoots, a trim that eats a workout id —
/// is pinned down here, without an SDK.
struct CoachPromptBudgetTests {

    /// Shaped like `AICoachService.makePlanAdaptationContext`: sections separated by a
    /// blank line, history newest first, workout ids in a later section.
    private func planPrompt(runCount: Int) -> String {
        let runs = (0..<runCount)
            .map { "Sep \(20 - $0), 2026 | Easy | 8.0 km | pace 5:30/km | 44:00 | HR 142" }
            .joined(separator: "\n")
        return """
        Adapt these 2 scheduled workouts as one coordinated plan update.

        Athlete:
        Target race: Marathon
        Goal time: 3:30:00

        Recent completed runs:
        \(runs)

        Scheduled workouts:
        11111111-1111-1111-1111-111111111111 | Sep 22, 2026 Mon | Easy
        22222222-2222-2222-2222-222222222222 | Sep 24, 2026 Wed | Tempo
        """
    }

    // MARK: Size estimate

    @Test("The token estimate rounds up and runs ahead of the real count")
    func estimateRoundsUp() {
        #expect(CoachPromptBudget.estimatedTokenCount(of: "") == 0)
        // Ceiling, not truncation: a one-character prompt costs a token, not none.
        #expect(CoachPromptBudget.estimatedTokenCount(of: "a") == 1)
        #expect(CoachPromptBudget.estimatedTokenCount(of: "abc") == 1)
        #expect(CoachPromptBudget.estimatedTokenCount(of: "abcd") == 2)

        // The estimate must overshoot, never undershoot: undershooting sends a prompt the
        // model cannot hold, while overshooting drops one extra run.
        let prose = String(repeating: "the runner held an even pace throughout ", count: 20)
        let realisticProseTokens = prose.count / 4  // ~4 characters per token for prose
        #expect(CoachPromptBudget.estimatedTokenCount(of: prose) > realisticProseTokens)
    }

    @Test("A UUID is not charged at prose rates")
    func estimateCoversIdHeavyRows() {
        // The plan prompt carries one 36-character UUID per workout, and ids tokenize far
        // worse than words. The estimate should not come in under one token per three
        // characters for them.
        let id = "11111111-1111-1111-1111-111111111111"
        #expect(id.count == 36)
        #expect(CoachPromptBudget.estimatedTokenCount(of: id) == 12)
    }

    // MARK: Trimming

    @Test("The oldest run is the row that goes")
    func dropsTheOldestRun() throws {
        let trimmed = try #require(CoachPromptBudget.droppingOldestHistoryRow(from: planPrompt(runCount: 3)))

        // History is newest first, so the oldest run is the last row of the block.
        #expect(trimmed.contains("Sep 20, 2026"))
        #expect(trimmed.contains("Sep 19, 2026"))
        #expect(!trimmed.contains("Sep 18, 2026"))
        #expect(CoachPromptBudget.historyRowCount(in: trimmed) == 2)
    }

    @Test("Everything the response is validated against survives trimming")
    func keepsTheQuestionIntact() throws {
        var prompt = planPrompt(runCount: 8)
        // Trim past the point where the history block is exhausted.
        for _ in 0..<12 {
            guard let next = CoachPromptBudget.droppingOldestHistoryRow(from: prompt) else { break }
            prompt = next
        }

        // The workout ids key the result in `adaptScheduledWorkoutsWithProvider`; losing
        // one drops that workout's adaptation on the floor.
        #expect(prompt.contains("11111111-1111-1111-1111-111111111111"))
        #expect(prompt.contains("22222222-2222-2222-2222-222222222222"))
        #expect(prompt.contains("Target race: Marathon"))
        #expect(prompt.contains("Goal time: 3:30:00"))
        #expect(prompt.contains("Recent completed runs:"))
    }

    @Test("The last run is kept, so the coach is never left citing history it was not given")
    func stopsAtOneRow() {
        let single = planPrompt(runCount: 1)

        #expect(CoachPromptBudget.historyRowCount(in: single) == 1)
        #expect(CoachPromptBudget.droppingOldestHistoryRow(from: single) == nil)
    }

    @Test("A prompt with no history block is left alone")
    func noHistoryBlockIsUntouched() {
        // The single-workout adaptation prompt carries no recent-runs section.
        let prompt = """
        Adapt the scheduled run using only the athlete and workout context below.

        Athlete:
        Target race: 5K
        """

        #expect(CoachPromptBudget.historyRowCount(in: prompt) == 0)
        #expect(CoachPromptBudget.droppingOldestHistoryRow(from: prompt) == nil)
    }

    @Test("Every header the prompt builders emit is recognised")
    func recognisesEveryHeader() {
        // These are the literal headers in `AICoachService`'s prompt builders and
        // `AICoachChatView.coachContext`. A header that drifts out of this list stops
        // being trimmable, silently, so it is asserted rather than assumed.
        for header in ["Recent completed runs:", "Recent history:", "Recent runs:"] {
            let prompt = """
            \(header)
            Sep 20, 2026 | Easy | 8.0 km
            Sep 19, 2026 | Easy | 6.0 km

            Scheduled workouts:
            none
            """

            #expect(CoachPromptBudget.historyRowCount(in: prompt) == 2, "\(header) was not read as history")
            let trimmed = CoachPromptBudget.droppingOldestHistoryRow(from: prompt)
            #expect(trimmed?.contains("Sep 19") == false, "\(header) kept its oldest row")
        }
    }

    @Test("Only the first history block is trimmed")
    func trimsOneBlockAtATime() throws {
        // The chat prompt carries the runner context and the conversation, and both can
        // name recent runs. Trimming should take a row from the first block rather than
        // interleaving the two.
        let prompt = """
        Recent runs:
        Sep 20, 2026 | Easy
        Sep 19, 2026 | Easy

        Recent history:
        Sep 18, 2026 | Long Run
        """

        let trimmed = try #require(CoachPromptBudget.droppingOldestHistoryRow(from: prompt))
        #expect(trimmed.contains("Sep 20, 2026"))
        #expect(!trimmed.contains("Sep 19, 2026"))
        #expect(trimmed.contains("Sep 18, 2026"))
    }

    @Test("No tools reserve nothing; each tool adds its text, schema and a share of calls")
    func toolReserve() {
        #expect(CoachPromptBudget.toolReserve(toolTexts: []) == 0)
        let text = "findRuns Finds the runner's past runs."
        let one = CoachPromptBudget.toolReserve(toolTexts: [text])
        let expectedOne = CoachPromptBudget.estimatedTokenCount(of: text)
            + CoachPromptBudget.schemaTokensPerTool
            + CoachPromptBudget.expectedToolCalls * CoachPromptBudget.tokensPerToolCall
        #expect(one == expectedOne)
        let two = CoachPromptBudget.toolReserve(toolTexts: [text, text])
        #expect(two - one == CoachPromptBudget.estimatedTokenCount(of: text) + CoachPromptBudget.schemaTokensPerTool)
    }
}
