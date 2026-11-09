import Foundation
import Testing
@testable import Stride

// MARK: - NextSessionUpdate tests
//
// The captions are the exact words the coach page always showed; the colour now comes
// from the case instead of `hasPrefix("Updated")` on the text.

struct NextSessionUpdateTests {

    @Test("Idle shows no caption and is not applying")
    func idle() {
        let state = NextSessionUpdate.idle
        #expect(state.message == nil)
        #expect(!state.isApplying)
        #expect(state.updatedSessionID == nil)
    }

    @Test("Applying names the session and disables the button")
    func applying() {
        let state = NextSessionUpdate.applying(label: "Thu Nov 12 Tempo")
        #expect(state.isApplying)
        #expect(state.message == "Updating Thu Nov 12 Tempo...")
        #expect(!state.isSuccess)
    }

    @Test("Updated is the only green caption, and stands the button down for that session")
    func updated() {
        let id = UUID()
        let state = NextSessionUpdate.updated(id: id, label: "Thu Nov 12 Tempo")
        #expect(state.message == "Updated Thu Nov 12 Tempo in your plan.")
        #expect(state.isSuccess)
        #expect(state.updatedSessionID == id)
        #expect(!state.isApplying)
    }

    @Test("A refusal and a failure read as status, not success")
    func refusalAndFailure() {
        let refused = NextSessionUpdate.unavailable("Turn on AI Coach in Settings to update the plan.")
        #expect(refused.message == "Turn on AI Coach in Settings to update the plan.")
        #expect(!refused.isSuccess)

        let failed = NextSessionUpdate.failed
        #expect(failed.message == "The coach feedback could not be applied. Try refreshing the AI analysis.")
        #expect(!failed.isSuccess)
        #expect(failed.updatedSessionID == nil)
    }

    @Test("A session label starting with 'Updated' no longer turns a status green")
    func colourIsNotFromText() {
        let state = NextSessionUpdate.unavailable("Updated workouts are not available yet.")
        #expect(!state.isSuccess)
    }
}
