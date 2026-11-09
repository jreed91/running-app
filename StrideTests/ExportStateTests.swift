import Testing
@testable import Stride

// MARK: - ExportState tests
//
// The data export, share card and GPX export share this lifecycle. A String stands in
// for the file.

struct ExportStateTests {

    private typealias State = ExportState<String>

    @Test("Idle shows no spinner, sheet or alert")
    func idle() {
        let state = State.idle
        #expect(!state.isWorking)
        #expect(state.output == nil)
        #expect(state.errorMessage == nil)
    }

    @Test("Working, then ready: the sheet gets the file")
    func succeed() {
        var state = State.idle
        state.begin()
        #expect(state.isWorking)
        state.succeed("archive.zip")
        #expect(!state.isWorking)
        #expect(state.output == "archive.zip")
        #expect(state.errorMessage == nil)
    }

    @Test("Working, then failed: the alert gets the message, no sheet")
    func fail() {
        var state = State.idle
        state.begin()
        state.fail("Disk full")
        #expect(state.errorMessage == "Disk full")
        #expect(state.output == nil)
        #expect(!state.isWorking)
    }

    @Test("A failure before any work starts still shows the alert")
    func failWithoutWorking() {
        var state = State.idle
        state.fail("Fetch failed")
        #expect(state.errorMessage == "Fetch failed")
    }

    @Test("Dismissing the sheet or the alert returns to idle")
    func dismiss() {
        var ready = State.ready("a.gpx")
        ready.dismiss()
        #expect(ready == .idle)
        var failed = State.failed("Disk full")
        failed.dismiss()
        #expect(failed == .idle)
    }

    @Test("Dismiss never cancels work in flight")
    func dismissWhileWorking() {
        var state = State.working
        state.dismiss()
        #expect(state.isWorking)
    }

    @Test("Abandon ends work that produced nothing, and leaves a result alone")
    func abandon() {
        var working = State.working
        working.abandon()
        #expect(working == .idle)
        var ready = State.ready("card.png")
        ready.abandon()
        #expect(ready == .ready("card.png"))
    }
}
