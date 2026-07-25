import Foundation

// MARK: - CoachMarkdown

/// Renders the coach's lightly-marked-up text for display.
///
/// The model returns prose with occasional `**bold**`, backticks, or list markers.
/// `RunSummaryView` grew five near-identical private copies of this logic — one on the
/// view and one inside each nested row type (N27) — so a fix to any of them reached
/// only the paragraphs that happened to use that copy. This is the single definition.
enum CoachMarkdown {

    /// Inline markup that `AttributedString(markdown:)` can't be trusted to have
    /// handled when it throws, stripped so the fallback reads as plain prose.
    private static let inlineMarkers = ["**", "__", "`", "###", "##", "#", ">", "_"]

    private static let listPrefixes = ["- ", "* ", "+ "]

    /// The text with inline markup and any leading list marker removed.
    static func stripped(_ text: String) -> String {
        var output = text
        inlineMarkers.forEach { output = output.replacingOccurrences(of: $0, with: "") }

        for prefix in listPrefixes where output.hasPrefix(prefix) {
            output.removeFirst(prefix.count)
        }
        if let range = output.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            output.removeSubrange(range)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text as an `AttributedString` with inline markup applied, falling back to
    /// `stripped(_:)` when the markdown parser rejects it — never showing raw asterisks.
    static func attributed(_ text: String) -> AttributedString {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let attributed = try? AttributedString(
            markdown: trimmed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(stripped(trimmed))
    }
}
