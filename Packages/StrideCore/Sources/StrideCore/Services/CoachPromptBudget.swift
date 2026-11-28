import Foundation

/// Pre-flight trimming for coach prompts that can outgrow a model's context window.
///
/// The backend reads each model's `contextSize`, where the model's concrete type is in
/// hand. Everything else lives here, in plain Foundation with no `FoundationModels`
/// import: both the rule for what a prompt is allowed to lose and the estimate of what it
/// costs, so the parts that can silently produce a wrong answer are testable without an
/// iOS SDK.
///
/// The rule is deliberately narrow: only the recent-run history block shrinks, and it
/// shrinks from its oldest end. Everything else in these prompts is either the question
/// itself (the scheduled workouts, the run being analysed) or something the response is
/// validated against downstream (the workout ids `adaptScheduledWorkoutsWithProvider`
/// keys its result on), so dropping any of it buys tokens at the price of a wrong
/// answer. Losing the oldest run costs the coach context it already weights least.
enum CoachPromptBudget {

    /// Characters per token this assumes when sizing a prompt.
    ///
    /// Deliberately low. English prose runs around four characters per token, but these
    /// prompts are not prose: they are pipe-separated metric rows, clock times, paces and
    /// — in the plan-adaptation prompt — a 36-character UUID per workout, all of which
    /// tokenize far worse than words do. Three characters per token overshoots the token
    /// count for text like that, and overshooting is the safe direction here: it trims one
    /// run too early rather than sending a prompt the model cannot hold.
    ///
    /// This is an estimate because the real measurement could not be made to compile
    /// against the shipping SDK. `tokenCount(for:)` is not a `LanguageModel` protocol
    /// member, and the concrete `SystemLanguageModel.tokenCount(for:)` takes an
    /// `Instructions` value rather than a `String`:
    ///
    ///     nonisolated(nonsending)
    ///     final func tokenCount(for instructions: Instructions) async throws -> Int
    ///
    /// Restoring the real count means converting these `String` prompts into `Prompt` /
    /// `Instructions` values and finding the matching overload on
    /// `PrivateCloudComputeLanguageModel` too. Worth doing on a machine that can compile
    /// it; not worth guessing at from here, which is how the first attempt broke the
    /// archive build. The *window* is still read from the model — only the prompt's size
    /// is estimated.
    static let charactersPerToken = 3

    /// Tokens a session with tools holds back before the prompt is sized.
    ///
    /// Tools cost context twice. Each tool's name, description and argument schema go
    /// into the prompt verbatim, and every call the model makes adds its arguments and
    /// the tool's answer to the transcript before the reply is written. Neither is in
    /// the prompt string `estimatedTokenCount(of:)` measures, so without this a prompt
    /// that fits on its own can overflow the on-device window once tools are attached.
    ///
    /// - Parameter toolTexts: each tool's name and description.
    static func toolReserve(toolTexts: [String]) -> Int {
        guard !toolTexts.isEmpty else { return 0 }
        return toolTexts.reduce(0) { $0 + estimatedTokenCount(of: $1) + schemaTokensPerTool }
            + expectedToolCalls * tokensPerToolCall
    }

    /// A generous estimate of one tool's argument schema in the prompt: two or three
    /// fields, each with a short guide and a range or an enum's cases.
    static let schemaTokensPerTool = 60
    /// Lookups a typical answer makes. More are allowed; this sizes the reserve.
    static let expectedToolCalls = 2
    /// One call's arguments and answer: up to `CoachLookup.maximumRows` lines of about a
    /// hundred characters each.
    static let tokensPerToolCall = 350

    /// Roughly how many tokens `text` will cost, rounded up.
    static func estimatedTokenCount(of text: String) -> Int {
        (text.count + charactersPerToken - 1) / charactersPerToken
    }

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
