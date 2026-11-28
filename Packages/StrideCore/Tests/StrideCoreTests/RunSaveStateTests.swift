import Testing
@testable import StrideCore

// MARK: - RunSaveState tests
//
// A finished run lives only in memory until it is saved (N15). These pin the hand-offs
// between the Finish dialog, the save, and the "Couldn't save your run" alert, with a
// String standing in for the `RunWorkout`.

struct RunSaveStateTests {

    @Test("Nothing held before a run is finished")
    func startsUnsaved() {
        let state = RunSaveState<String>.unsaved
        #expect(state.heldRun == nil)
        #expect(state.errorMessage == nil)
    }

    @Test("Finishing holds the run with no error")
    func holdKeepsRun() {
        var state = RunSaveState<String>.unsaved
        state.hold("run")
        #expect(state == .held("run"))
        #expect(state.errorMessage == nil)
    }

    @Test("A failed save shows its message and keeps the run")
    func failKeepsRunAndMessage() {
        var state = RunSaveState<String>.unsaved
        state.hold("run")
        state.fail("run", message: "Disk full")
        #expect(state.heldRun == "run")
        #expect(state.errorMessage == "Disk full")
    }

    @Test("Try Again clears the error and hands back the same run")
    func retryHandsBackRun() {
        var state = RunSaveState<String>.failed("run", message: "Disk full")
        let toSave = state.retry()
        #expect(toSave == "run")
        #expect(state == .held("run"))
    }

    @Test("Try Again with nothing held hands back nil")
    func retryWithNothingHeld() {
        var state = RunSaveState<String>.unsaved
        let toSave = state.retry()
        #expect(toSave == nil)
        #expect(state == .unsaved)
    }

    @Test("Dismissing the alert keeps the run, so Finish saves it again")
    func dismissKeepsRun() {
        var state = RunSaveState<String>.failed("run", message: "Disk full")
        state.dismissError()
        #expect(state == .held("run"))
        state.dismissError()
        #expect(state == .held("run"))
    }

    @Test("A successful save or a discard leaves nothing held")
    func clearReleasesRun() {
        var saved = RunSaveState<String>.held("run")
        saved.clear()
        #expect(saved == .unsaved)

        var discarded = RunSaveState<String>.failed("run", message: "Disk full")
        discarded.clear()
        #expect(discarded.heldRun == nil)
        #expect(discarded.errorMessage == nil)
    }
}
