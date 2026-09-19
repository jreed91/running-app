import Foundation
import Testing
@testable import Stride

/// Covers `CoachMarkdown`, the single definition replacing the six near-identical
/// private sanitizers that had accumulated across the coach UI (N27).
struct CoachMarkdownTests {

    @Test("Inline markers and list prefixes are stripped from the plain form")
    func strippedRemovesMarkup() {
        #expect(CoachMarkdown.stripped("**Strong** finish") == "Strong finish")
        #expect(CoachMarkdown.stripped("- Ease off tomorrow") == "Ease off tomorrow")
        #expect(CoachMarkdown.stripped("1. Ease off tomorrow") == "Ease off tomorrow")
        #expect(CoachMarkdown.stripped("## Heading  ") == "Heading")
        #expect(CoachMarkdown.stripped("`pace` and _tone_") == "pace and tone")
    }

    @Test("Bold markup renders as attributed text without its asterisks")
    func attributedAppliesInlineMarkdown() {
        let rendered = String(CoachMarkdown.attributed("**Strong** finish").characters)
        #expect(rendered == "Strong finish")
    }

    /// The fallback matters most: whatever the model returns, the runner must never
    /// see raw markup in the UI.
    @Test("Unparseable markup still renders as clean prose")
    func attributedFallsBackToStripped() {
        let rendered = String(CoachMarkdown.attributed("### Recovery `week`").characters)
        #expect(!rendered.contains("#"))
        #expect(!rendered.contains("`"))
        #expect(rendered.contains("Recovery"))
    }
}

/// Covers `CoachMarkdown.blocks(_:)`, which splits a coach reply into the pieces
/// `CoachText` lays out. The single-`Text` rendering it replaces only ever stripped a
/// marker from the first line, so everything after it reached the screen raw.
struct CoachMarkdownBlockTests {

    @Test("Prose with no markup is one paragraph")
    func plainProseIsOneBlock() {
        let blocks = CoachMarkdown.blocks("You held a steady pace the whole way.")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
        #expect(blocks[0].text == "You held a steady pace the whole way.")
    }

    @Test("A blank line starts a new paragraph, a single newline does not")
    func blankLinesSeparateParagraphs() {
        let blocks = CoachMarkdown.blocks("First line.\nStill the first paragraph.\n\nSecond paragraph.")
        #expect(blocks.count == 2)
        #expect(blocks[0].text == "First line. Still the first paragraph.")
        #expect(blocks[1].text == "Second paragraph.")
    }

    @Test("List markers become list items with the marker removed")
    func listMarkersBecomeItems() {
        let blocks = CoachMarkdown.blocks("- Keep tomorrow easy\n* Drink early\n• Sleep")
        #expect(blocks.count == 3)
        #expect(blocks.allSatisfy { $0.kind == .bullet })
        #expect(blocks.map(\.text) == ["Keep tomorrow easy", "Drink early", "Sleep"])
    }

    @Test("Numbered items keep the number the model wrote")
    func numberedItemsKeepTheirNumber() {
        let blocks = CoachMarkdown.blocks("1. Warm up\n2. Run the set")
        #expect(blocks.map(\.kind) == [.numbered(1), .numbered(2)])
        #expect(blocks.map(\.text) == ["Warm up", "Run the set"])
    }

    /// The failure that made replies hard to read: a heading or a bullet on any line
    /// but the first kept its marker, because `attributed(_:)` only sees the head of
    /// the string it is handed.
    @Test("Markers after the first line are removed too")
    func markersBeyondTheFirstLineAreRemoved() {
        let blocks = CoachMarkdown.blocks("Nice work today.\n\n## Tomorrow\n- Easy 5 km")
        #expect(blocks.count == 3)
        #expect(blocks[1].kind == .heading)
        #expect(blocks[1].text == "Tomorrow")
        #expect(blocks[2].kind == .bullet)
        #expect(blocks[2].text == "Easy 5 km")
        #expect(blocks.allSatisfy { !$0.text.contains("#") && !$0.text.hasPrefix("- ") })
    }

    @Test("Inline markup survives for the attributed pass to apply")
    func inlineMarkupIsLeftForTheRenderer() {
        let blocks = CoachMarkdown.blocks("- Hold **5:20 per km**")
        #expect(blocks[0].text == "Hold **5:20 per km**")
        #expect(String(CoachMarkdown.attributed(blocks[0].text).characters) == "Hold 5:20 per km")
    }

    @Test("Empty and whitespace-only text produces no blocks")
    func emptyTextProducesNothing() {
        #expect(CoachMarkdown.blocks("").isEmpty)
        #expect(CoachMarkdown.blocks("   \n\n  ").isEmpty)
    }

    @Test("Block ids are unique so ForEach can key on them")
    func idsAreUnique() {
        let blocks = CoachMarkdown.blocks("One.\n\n- Two\n- Three\n\nFour.")
        #expect(Set(blocks.map(\.id)).count == blocks.count)
    }
}
