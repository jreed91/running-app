import Testing
import Foundation
@testable import Stride

// MARK: - WallClockStopwatch tests
//
// Covers the wall-clock elapsed accumulator behind M23 (timer-tick undercount)
// and, by extension, the pause/resume banking that keeps duration correct across
// a suspended process.

struct WallClockStopwatchTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test("Elapsed grows with wall-clock time while running")
    func elapsedTracksWallClock() {
        var sw = WallClockStopwatch()
        sw.start(at: t0)
        #expect(sw.elapsed(at: t0) == 0)
        #expect(sw.elapsed(at: t0.addingTimeInterval(42)) == 42)
    }

    @Test("Paused time does not count toward elapsed")
    func pauseExcludesGap() {
        var sw = WallClockStopwatch()
        sw.start(at: t0)
        sw.pause(at: t0.addingTimeInterval(30))       // banked 30 s
        // 60 s pass while paused
        #expect(sw.elapsed(at: t0.addingTimeInterval(90)) == 30)
        sw.resume(at: t0.addingTimeInterval(90))
        #expect(sw.elapsed(at: t0.addingTimeInterval(100)) == 40)  // 30 + 10
    }

    @Test("Elapsed is immune to a suspended process (no ticks) — jumps to real total")
    func survivesSuspension() {
        var sw = WallClockStopwatch()
        sw.start(at: t0)
        // Process suspended for an hour with zero timer fires; the next read is correct.
        #expect(sw.elapsed(at: t0.addingTimeInterval(3600)) == 3600)
    }

    @Test("Multiple pause/resume cycles accumulate only active time")
    func multipleCycles() {
        var sw = WallClockStopwatch()
        sw.start(at: t0)
        sw.pause(at: t0.addingTimeInterval(10))       // +10 (10 total)
        sw.resume(at: t0.addingTimeInterval(20))
        sw.pause(at: t0.addingTimeInterval(35))       // +15 (25 total)
        sw.resume(at: t0.addingTimeInterval(50))
        #expect(sw.elapsed(at: t0.addingTimeInterval(55)) == 30)  // 25 + 5
    }

    @Test("Resume is a no-op while already running")
    func resumeWhileRunningNoOp() {
        var sw = WallClockStopwatch()
        sw.start(at: t0)
        sw.resume(at: t0.addingTimeInterval(100))     // ignored
        #expect(sw.elapsed(at: t0.addingTimeInterval(10)) == 10)
    }

    @Test("Reset returns to zeroed, stopped state")
    func resetClears() {
        var sw = WallClockStopwatch()
        sw.start(at: t0)
        sw.pause(at: t0.addingTimeInterval(10))
        sw.reset()
        #expect(sw.accumulated == 0)
        #expect(sw.isRunning == false)
        #expect(sw.elapsed(at: t0.addingTimeInterval(999)) == 0)
    }

    @Test("Start after finishing discards prior accumulation")
    func restartIsClean() {
        var sw = WallClockStopwatch()
        sw.start(at: t0)
        sw.pause(at: t0.addingTimeInterval(300))
        sw.start(at: t0.addingTimeInterval(1000))     // new run
        #expect(sw.elapsed(at: t0.addingTimeInterval(1010)) == 10)
    }
}
