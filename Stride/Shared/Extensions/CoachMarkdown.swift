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

    private static let listPrefixes = ["- ", "* ", "+ ", "• "]

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

    /// Block-level markers, longest first so `###` is matched before `#`.
    private static let blockPrefixes = ["######", "#####", "####", "###", "##", "#", ">"]

    /// The text with any leading block-level marker removed.
    ///
    /// `attributed(_:)` parses inline-only, and to that parser a heading is not markup at
    /// all: it does not throw on `### Recovery`, it hands back `### Recovery` with the
    /// hashes intact. So the `stripped(_:)` fallback never ran and the coach's headings
    /// reached the screen as literal hashes.
    ///
    /// Inline markers are deliberately left alone here — those the parser *does*
    /// understand, and stripping them first would flatten `**bold**` into plain prose.
    private static func withoutBlockMarkup(_ text: String) -> String {
        guard let prefix = blockPrefixes.first(where: { text.hasPrefix($0) }) else { return text }
        return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text as an `AttributedString` with inline markup applied, falling back to
    /// `stripped(_:)` when the markdown parser rejects it — never showing raw asterisks.
    static func attributed(_ text: String) -> AttributedString {
        let trimmed = withoutBlockMarkup(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let attributed = try? AttributedString(
            markdown: trimmed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(stripped(trimmed))
    }
}

// MARK: - Block structure

extension CoachMarkdown {

    /// One renderable piece of a coach reply: a paragraph, a heading, or a list item.
    ///
    /// A reply is not one run of prose. The model writes paragraphs, and when it is
    /// listing things it writes `- ` lines and `1. ` lines. Handing the whole reply to a
    /// single `Text` rendered all of that as one block with the markers still in it,
    /// because `attributed(_:)` strips a block marker only from the *start* of the
    /// string it is given — the first line of a reply, and nothing after it. Splitting
    /// the reply first means every line gets that treatment, and a list can be laid out
    /// as a list instead of as a paragraph with hyphens in the middle of it.
    struct Block: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case paragraph
            case heading
            /// A bulleted item.
            case bullet
            /// A numbered item, carrying the number the model wrote.
            case numbered(Int)
        }

        /// Position in the reply. Stable for the lifetime of a given string, which is
        /// all `ForEach` needs, and cheaper than hashing the text.
        let id: Int
        let kind: Kind
        /// The line's text with its block marker removed. Inline markup is left in
        /// place for `attributed(_:)` to apply.
        let text: String
    }

    /// `text` split into the blocks a coach reply is actually made of.
    ///
    /// Follows the markdown convention the model is writing to: a blank line ends a
    /// paragraph, consecutive plain lines are one paragraph, and a list marker starts a
    /// new item. Anything unrecognised is prose, so a reply with no markup at all comes
    /// back as one paragraph and renders exactly as it did before.
    static func blocks(_ text: String) -> [Block] {
        var parsed: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            parsed.append(
                Block(id: parsed.count, kind: .paragraph, text: paragraph.joined(separator: " "))
            )
            paragraph = []
        }

        func append(_ kind: Block.Kind, _ body: String) {
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            parsed.append(Block(id: parsed.count, kind: kind, text: trimmed))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                continue
            }

            if let prefix = blockPrefixes.first(where: { line.hasPrefix($0) }) {
                flushParagraph()
                append(.heading, String(line.dropFirst(prefix.count)))
                continue
            }

            if let prefix = listPrefixes.first(where: { line.hasPrefix($0) }) {
                flushParagraph()
                append(.bullet, String(line.dropFirst(prefix.count)))
                continue
            }

            if let range = line.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) {
                flushParagraph()
                let number = Int(line[range].prefix { $0.isNumber }) ?? parsed.count + 1
                append(.numbered(number), String(line[range.upperBound...]))
                continue
            }

            paragraph.append(line)
        }
        flushParagraph()

        return parsed
    }
}
