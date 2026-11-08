import Foundation
import Testing
@testable import Stride

// MARK: - Indoor run keepalive (P2.1)
//
// An indoor run starts an iPhone workout session so the app keeps running with the phone
// locked, and ends it when the run finishes. These pin when the tracker asks for that.
// They drive a real `WorkoutTrackerService` indoors only: an outdoor start opens a
// location session, which a unit test has no business doing.

@MainActor
private final class RecordingKeepalive: IndoorRunKeepalive {
    var starts: [Date] = []
    var ends = 0
    func indoorRunDidStart(at date: Date) { starts.append(date) }
    func indoorRunDidEnd() { ends += 1 }
}

@MainActor
struct IndoorRunKeepaliveTests {

    private func makeTracker(keepalive: RecordingKeepalive) -> WorkoutTrackerService {
        let tracker = WorkoutTrackerService()
        tracker.checkpointURL = nil
        tracker.indoorKeepalive = keepalive
        tracker.setLocation(.indoor)
        return tracker
    }

    @Test("An indoor run starts the session once and ends it at the finish")
    func indoorRunStartsAndEndsTheSession() {
        let keepalive = RecordingKeepalive()
        let tracker = makeTracker(keepalive: keepalive)

        tracker.startWorkout(type: .easy)
        #expect(keepalive.starts.count == 1)
        #expect(keepalive.ends == 0)

        _ = tracker.finishWorkout()
        #expect(keepalive.ends == 1)
    }

    @Test("Pausing and resuming leave the session running")
    func pauseKeepsTheSession() {
        let keepalive = RecordingKeepalive()
        let tracker = makeTracker(keepalive: keepalive)

        tracker.startWorkout(type: .easy)
        tracker.pauseWorkout()
        tracker.resumeWorkout()
        #expect(keepalive.starts.count == 1)
        #expect(keepalive.ends == 0)

        _ = tracker.finishWorkout()
        #expect(keepalive.ends == 1)
    }

    @Test("A finish with no run recording does not touch the session")
    func finishWithoutRunIsIgnored() {
        let keepalive = RecordingKeepalive()
        let tracker = makeTracker(keepalive: keepalive)

        #expect(tracker.finishWorkout() == nil)
        #expect(keepalive.starts.isEmpty)
        #expect(keepalive.ends == 0)
    }

    @Test("Ending with no session started is a no-op")
    func endWithoutStartIsSafe() {
        let session = IndoorRunWorkoutSession()
        session.indoorRunDidEnd()
        session.indoorRunDidEnd()
    }
}
