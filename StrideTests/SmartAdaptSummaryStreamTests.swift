import Foundation
import Testing
@testable import Stride

/// Covers `SmartAdaptSummaryStream`, the partial-JSON scanner that used to live in
/// `PlanTabView` (D1). It reads a document that is by definition incomplete, so the
/// cases that matter are the half-written ones.
struct SmartAdaptSummaryStreamTests {

    // MARK: Streaming

    @Test("Nothing is returned before the summary array is reached")
    func emptyBeforeArray() {
        #expect(SmartAdaptSummaryStream.summaries(in: "").isEmpty)
        #expect(SmartAdaptSummaryStream.summaries(in: "{\"workouts\": [").isEmpty)
        // The key has arrived but the array has not.
        #expect(SmartAdaptSummaryStream.summaries(in: "{\"summary\"").isEmpty)
    }

    @Test("A half-written element is withheld until its closing quote arrives")
    func partialElementIsNotPublished() {
        let buffer = "{\"summary\": [\"Eased Tuesday back\", \"Kept Thursd"
        let summaries = SmartAdaptSummaryStream.summaries(in: buffer)

        // Publishing the partial one would flicker the card through "Kept Thursd".
        #expect(summaries == ["Eased Tuesday back"])
    }

    @Test("Each closed element is published in document order")
    func completedElementsInOrder() {
        let buffer = "{\"summary\": [\"First\", \"Second\", \"Third\"]}"

        #expect(SmartAdaptSummaryStream.summaries(in: buffer) == ["First", "Second", "Third"])
    }

    @Test("Scanning stops at the array's closing bracket")
    func stopsAtCloseBracket() {
        // Strings after the array — the coach's prose fields — must not be mistaken
        // for summaries.
        let buffer = "{\"summary\": [\"Only this\"], \"headline\": \"Not this\"}"

        #expect(SmartAdaptSummaryStream.summaries(in: buffer) == ["Only this"])
    }

    // MARK: Escapes

    @Test("Escaped quotes stay inside their element rather than ending it")
    func escapedQuoteDoesNotCloseElement() {
        let buffer = #"{"summary": ["Called it a \"steady\" effort"]}"#

        #expect(SmartAdaptSummaryStream.summaries(in: buffer) == [#"Called it a "steady" effort"#])
    }

    @Test("Whitespace escapes are decoded, and a backslash escapes itself")
    func whitespaceAndBackslashEscapes() {
        let buffer = #"{"summary": ["Line one\nLine two", "Tab\there", "Back\\slash"]}"#

        #expect(SmartAdaptSummaryStream.summaries(in: buffer) == [
            "Line one\nLine two",
            "Tab\there",
            #"Back\slash"#
        ])
    }

    // MARK: Empty elements

    @Test("Blank and whitespace-only elements are dropped, not shown as empty bullets")
    func blankElementsAreDropped() {
        let buffer = "{\"summary\": [\"\", \"   \", \"Real one\"]}"

        #expect(SmartAdaptSummaryStream.summaries(in: buffer) == ["Real one"])
    }

    @Test("Elements are trimmed of surrounding whitespace")
    func elementsAreTrimmed() {
        let buffer = "{\"summary\": [\"  Padded  \"]}"

        #expect(SmartAdaptSummaryStream.summaries(in: buffer) == ["Padded"])
    }

    // MARK: Growing buffer

    @Test("Re-scanning a growing buffer never loses or reorders what it already had")
    func growingBufferIsMonotonic() {
        let full = "{\"summary\": [\"Alpha\", \"Beta\", \"Gamma\"]}"
        var seen: [[String]] = []

        // The view re-scans the whole accumulated buffer on every chunk, so each
        // prefix's result must be a prefix of the next one's.
        for length in 1...full.count {
            let prefix = String(full.prefix(length))
            seen.append(SmartAdaptSummaryStream.summaries(in: prefix))
        }

        for (earlier, later) in zip(seen, seen.dropFirst()) {
            #expect(later.count >= earlier.count)
            #expect(Array(later.prefix(earlier.count)) == earlier)
        }
        #expect(seen.last == ["Alpha", "Beta", "Gamma"])
    }
}
