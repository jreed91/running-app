import Testing
@testable import Stride

// MARK: - CoachReplyStream tests
//
// The coach chat and the run's coaching read both draw from this: typing dots or a
// skeleton while `.waiting`, the text so far while `.streaming`, and their own result
// once `.idle` again.

struct CoachReplyStreamTests {

    @Test("Idle is inactive with no text")
    func idle() {
        let stream = CoachReplyStream.idle
        #expect(!stream.isActive)
        #expect(stream.partialText.isEmpty)
    }

    @Test("Begin waits for the first words")
    func beginWaits() {
        var stream = CoachReplyStream.idle
        stream.begin()
        #expect(stream == .waiting)
        #expect(stream.isActive)
        #expect(stream.partialText.isEmpty)
    }

    @Test("Each partial replaces the text: partials are cumulative snapshots")
    func partialsReplace() {
        var stream = CoachReplyStream.idle
        stream.begin()
        stream.receive("Nice")
        #expect(stream == .streaming("Nice"))
        stream.receive("Nice and steady")
        #expect(stream.partialText == "Nice and steady")
        #expect(stream.isActive)
    }

    @Test("An empty partial still reads as waiting, so the dots stay")
    func emptyPartialWaits() {
        var stream = CoachReplyStream.idle
        stream.begin()
        stream.receive("")
        #expect(stream == .waiting)
    }

    @Test("Finish clears the text from either active state")
    func finishClears() {
        var waiting = CoachReplyStream.idle
        waiting.begin()
        waiting.finish()
        #expect(waiting == .idle)

        var streaming = CoachReplyStream.idle
        streaming.begin()
        streaming.receive("Half a reply")
        streaming.finish()
        #expect(streaming == .idle)
        #expect(streaming.partialText.isEmpty)
    }

    @Test("A partial after finish is dropped rather than shown with nothing running")
    func partialAfterFinishIgnored() {
        var stream = CoachReplyStream.idle
        stream.receive("late")
        #expect(stream == .idle)
    }

    @Test("Beginning again starts from no text")
    func beginAgainResets() {
        var stream = CoachReplyStream.idle
        stream.begin()
        stream.receive("Old read")
        stream.finish()
        stream.begin()
        #expect(stream == .waiting)
    }
}
