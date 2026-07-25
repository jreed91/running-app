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
