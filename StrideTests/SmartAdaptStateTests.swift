import Testing
@testable import Stride

// MARK: - SmartAdaptState tests
//
// The outcome of a Smart Adapt run used to vanish with the panel the moment the run
// ended. These pin that it now stays, and that an abandoned run still clears.

struct SmartAdaptStateTests {

    @Test("Idle shows no panel")
    func idleShowsNothing() {
        let state = SmartAdaptState.idle
        #expect(!state.isRunning)
        #expect(!state.showsProgress)
        #expect(state.progress == .idle)
    }

    @Test("Start runs from the preparing message")
    func startRuns() {
        var state = SmartAdaptState.idle
        state.start()
        #expect(state.isRunning)
        #expect(state.progress.currentMessage == "Preparing plan...")
    }

    @Test("Progress writes land while running")
    func writesWhileRunning() {
        var state = SmartAdaptState.idle
        state.start()
        state.progress.totalCount = 4
        state.progress.completedCount = 1
        #expect(state.progress.fractionCompleted == 0.25)
    }

    @Test("Finishing keeps the outcome on the card")
    func finishKeepsOutcome() {
        var state = SmartAdaptState.idle
        state.start()
        state.progress.totalCount = 2
        state.progress.completedCount = 2
        state.finish(message: "Plan updated and synced.")
        #expect(!state.isRunning)
        #expect(state.showsProgress)
        #expect(state.progress.currentMessage == "Plan updated and synced.")
        #expect(state.progress.completedCount == 2)
    }

    @Test("A failure is kept too, so the runner can read why")
    func failureIsKept() {
        var state = SmartAdaptState.idle
        state.start()
        state.finish(message: "The coach response could not be applied.")
        #expect(state.progress.currentMessage == "The coach response could not be applied.")
        // The run's defer then stands down without touching it.
        state.stopIfRunning()
        #expect(state.showsProgress)
    }

    @Test("An abandoned run clears the card")
    func abandonedRunClears() {
        var state = SmartAdaptState.idle
        state.start()
        state.progress.currentMessage = "Streaming coach response..."
        state.stopIfRunning()
        #expect(state == .idle)
    }

    @Test("Writes after the run has finished are dropped")
    func lateWritesDropped() {
        var state = SmartAdaptState.idle
        state.start()
        state.finish(message: "Plan updated and synced.")
        state.progress.currentMessage = "Reading coach summary..."
        #expect(state.progress.currentMessage == "Plan updated and synced.")
    }

    @Test("Starting again replaces the last outcome")
    func restartReplacesOutcome() {
        var state = SmartAdaptState.idle
        state.start()
        state.finish(message: "Plan updated and synced.")
        state.start()
        #expect(state.isRunning)
        #expect(state.progress.currentMessage == "Preparing plan...")
    }

    @Test("finish() when not running does nothing")
    func finishWhenIdle() {
        var state = SmartAdaptState.idle
        state.finish(message: "Plan updated and synced.")
        #expect(state == .idle)
    }
}
