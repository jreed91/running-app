import Foundation
import Testing
@testable import Stride

/// Covers `SmartAdaptSummaryStream`, which turns the coach's streaming plan adaptation
/// into the lines Smart Adapt lists (D1).
///
/// The JSON-scanning cases these tests used to carry are gone with the scanner: guided
/// generation streams typed snapshots, and the backend publishes only the explanations
/// that are finished, so a half-written one never reaches here. What is left is the
/// shape of the text that does arrive.
struct SmartAdaptSummaryStreamTests {

    @Test("Nothing is returned before the coach has finished an explanation")
    func emptyBeforeFirstExplanation() {
        #expect(SmartAdaptSummaryStream.summaries(in: "").isEmpty)
        #expect(SmartAdaptSummaryStream.summaries(in: "\n").isEmpty)
        #expect(SmartAdaptSummaryStream.summaries(in: "   \n  ").isEmpty)
    }

    @Test("Each explanation is published in the order the coach wrote it")
    func explanationsInOrder() {
        let partial = "Eased Tuesday back\nKept Thursday's tempo\nShortened the long run"

        #expect(SmartAdaptSummaryStream.summaries(in: partial) == [
            "Eased Tuesday back",
            "Kept Thursday's tempo",
            "Shortened the long run"
        ])
    }

    @Test("A later snapshot supersedes the one before it")
    func snapshotsAreCumulative() {
        // The backend republishes everything finished so far, so the second snapshot
        // contains the first. A caller that appended them would list the first twice.
        let first = "Eased Tuesday back"
        let second = "Eased Tuesday back\nKept Thursday's tempo"

        #expect(SmartAdaptSummaryStream.summaries(in: first).count == 1)
        #expect(SmartAdaptSummaryStream.summaries(in: second).count == 2)
        #expect(SmartAdaptSummaryStream.summaries(in: second).first == first)
    }

    @Test("Blank lines are not listed as empty bullets")
    func blankLinesAreDropped() {
        let partial = "Eased Tuesday back\n\n   \nShortened the long run\n"

        #expect(SmartAdaptSummaryStream.summaries(in: partial) == [
            "Eased Tuesday back",
            "Shortened the long run"
        ])
    }

    @Test("The progress card shows a bounded number of summaries")
    func displayLimitIsBounded() {
        // The card is a few lines on a phone; the limit is what keeps a twelve-workout
        // adaptation from pushing the rest of the sheet off-screen.
        #expect(SmartAdaptSummaryStream.displayLimit > 0)
        #expect(SmartAdaptSummaryStream.displayLimit <= 6)
    }
}
