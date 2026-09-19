import Foundation

/// Pre-flight trimming for coach prompts that can outgrow a model's context window.
///
/// The measuring half (`tokenCount(for:)` / `contextSize`) lives in
/// `FoundationModelsCoachBackend`, where a model is in hand. The *editing* half lives
/// here, in plain Foundation with no `FoundationModels` import, so the rule for what a
/// prompt is allowed to lose is readable and testable without an iOS SDK.
///
/// The rule is deliberately narrow: only the recent-run history block shrinks, and it
/// shrinks from its oldest end. Everything else in these prompts is either the question
/// itself (the scheduled workouts, the run being analysed) or something the response is
/// validated against downstream (the workout ids `adaptScheduledWorkoutsWithProvider`
/// keys its result on), so dropping any of it buys tokens at the price of a wrong
/// answer. Losing the oldest run costs the coach context it already weights least.
enum CoachPromptBudget {

    /// The headers `AICoachService` writes above a block of recent runs. Each block runs
    /// until the first blank line, and its rows are newest first — every caller sorts
    /// history by date descending (`RunWorkout.runsOnlyDescriptor`) before formatting it.
    static let historyHeaders = [
        "Recent completed runs:",
        "Recent history:",
        "Recent runs:"
    ]

    /// `prompt` with the oldest run row removed, or `nil` when there is nothing left to
    /// drop — no history block, or one already down to a single row.
    ///
    /// The last row is kept on purpose. A history block trimmed to nothing would leave a
    /// bare header, and a coach that cites "your recent runs" with none supplied is worse
    /// than one working from a single run.
    static func droppingOldestHistoryRow(from prompt: String) -> String? {
        var lines = prompt.components(separatedBy: "\n")
        guard let block = historyBlock(in: lines), block.count > 1 else { return nil }
        lines.remove(at: block.upperBound - 1)
        return lines.joined(separator: "\n")
    }

    /// How many run rows `prompt` still carries. Used by the tests, and by the backend's
    /// trimming loop to tell "nothing more to give" from "one more pass to make".
    static func historyRowCount(in prompt: String) -> Int {
        historyBlock(in: prompt.components(separatedBy: "\n"))?.count ?? 0
    }

    /// The range of `lines` holding the first history block's rows, header excluded.
    ///
    /// A block ends at the first blank line, which is how every one of these prompts is
    /// laid out — sections separated by an empty line. A "no recent runs" placeholder is
    /// one row like any other and simply never has a second row to drop.
    private static func historyBlock(in lines: [String]) -> Range<Int>? {
        guard let headerIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return historyHeaders.contains(trimmed)
        }) else {
            return nil
        }

        let start = headerIndex + 1
        var end = start
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
            end += 1
        }
        return start < end ? start..<end : nil
    }
}
