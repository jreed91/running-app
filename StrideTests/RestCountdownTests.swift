import Testing
import Foundation
@testable import Stride

// MARK: - RestCountdown tests
//
// Covers the deadline-based strength rest timer behind M27 (the countdown
// previously froze while the app was suspended because it decremented a stored
// counter per tick instead of reading a fixed deadline).

struct RestCountdownTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test("Full duration remains at the moment the timer starts")
    func fullDurationAtStart() {
        let deadline = t0.addingTimeInterval(60)
        #expect(RestCountdown.secondsRemaining(deadline: deadline, now: t0) == 60)
    }

    @Test("Remaining tracks wall-clock elapsed, not tick count")
    func tracksWallClock() {
        let deadline = t0.addingTimeInterval(60)
        // 45 s pass (e.g. app was suspended and resumed) — the counter reflects
        // real elapsed time rather than however many ticks fired.
        #expect(RestCountdown.secondsRemaining(deadline: deadline, now: t0.addingTimeInterval(45)) == 15)
    }

    @Test("Rounds up so a partial second still reads as time left")
    func roundsUp() {
        let deadline = t0.addingTimeInterval(60)
        #expect(RestCountdown.secondsRemaining(deadline: deadline, now: t0.addingTimeInterval(59.2)) == 1)
    }

    @Test("Never returns a negative value once the deadline passes")
    func clampsAtZero() {
        let deadline = t0.addingTimeInterval(60)
        #expect(RestCountdown.secondsRemaining(deadline: deadline, now: deadline) == 0)
        #expect(RestCountdown.secondsRemaining(deadline: deadline, now: t0.addingTimeInterval(120)) == 0)
    }
}
