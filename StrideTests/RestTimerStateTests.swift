import Testing
import Foundation
@testable import Stride

// MARK: - RestTimerState tests
//
// Pins every transition of the strength rest timer, which used to be four loose
// `@State` variables on `StrengthActiveView`. The numbers here are the ones that view
// produced before the move, so a change in any of them is a behaviour change.

struct RestTimerStateTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test("Idle reads as no rest: nothing left, a full ring")
    func idleReadings() {
        let state = RestTimerState.idle
        #expect(!state.isResting)
        #expect(state.remainingSeconds == 0)
        #expect(state.progress == 1)
    }

    @Test("Start rests for the full length, deadline that far out")
    func startSetsDeadline() {
        let state = RestTimerState.start(seconds: 90, now: t0)
        #expect(state == .resting(.init(deadline: t0.addingTimeInterval(90), remainingSeconds: 90, totalSeconds: 90)))
        #expect(state.isResting)
        #expect(state.progress == 0)
    }

    @Test("A tick reads the time left from the wall clock, not a tick count")
    func tickTracksWallClock() {
        var state = RestTimerState.start(seconds: 60, now: t0)
        // The phone was locked for 45 s between ticks.
        state.tick(now: t0.addingTimeInterval(45))
        #expect(state.remainingSeconds == 15)
        #expect(state.progress == 0.75)
    }

    @Test("A tick that reaches the deadline ends the rest")
    func tickToZeroEnds() {
        var state = RestTimerState.start(seconds: 60, now: t0)
        state.tick(now: t0.addingTimeInterval(59.5))
        #expect(state.remainingSeconds == 1)
        state.tick(now: t0.addingTimeInterval(60))
        #expect(state == .idle)
        // The rest-over haptic keys on 1 -> 0.
        #expect(state.remainingSeconds == 0)
    }

    @Test("Ticking while idle does nothing")
    func tickWhenIdle() {
        var state = RestTimerState.idle
        state.tick(now: t0)
        #expect(state == .idle)
    }

    @Test("+15 s moves the deadline and the ring's length together")
    func adjustLonger() {
        var state = RestTimerState.start(seconds: 60, now: t0)
        let moved = state.adjust(by: 15, now: t0.addingTimeInterval(20))
        #expect(moved)
        #expect(state == .resting(.init(
            deadline: t0.addingTimeInterval(20 + 55),
            remainingSeconds: 55,
            totalSeconds: 75
        )))
    }

    @Test("−15 s with more than 15 s left keeps resting")
    func adjustShorter() {
        var state = RestTimerState.start(seconds: 60, now: t0)
        state.adjust(by: -15, now: t0.addingTimeInterval(10))
        #expect(state.remainingSeconds == 35)
        #expect(state.isResting)
    }

    @Test("−15 s with less than 15 s left ends the rest")
    func adjustToZeroEnds() {
        var state = RestTimerState.start(seconds: 60, now: t0)
        let moved = state.adjust(by: -15, now: t0.addingTimeInterval(50))
        #expect(moved)
        #expect(state == .idle)
    }

    @Test("The ring keeps its place after an adjustment")
    func progressAfterAdjust() {
        var state = RestTimerState.start(seconds: 60, now: t0)
        // 30 s in, then +30 s: 60 left of a 90 s rest, a third of the way round.
        state.adjust(by: 30, now: t0.addingTimeInterval(30))
        #expect(state.remainingSeconds == 60)
        #expect(abs(state.progress - 1.0 / 3.0) < 0.0001)
    }

    @Test("Adjusting while idle reports nothing moved")
    func adjustWhenIdle() {
        var state = RestTimerState.idle
        let moved = state.adjust(by: 15, now: t0)
        #expect(!moved)
        #expect(state == .idle)
    }

    @Test("End stops a running rest, and is harmless when idle")
    func endIsIdempotent() {
        var state = RestTimerState.start(seconds: 60, now: t0)
        state.end()
        #expect(state == .idle)
        state.end()
        #expect(state == .idle)
    }

    @Test("Starting again replaces the running rest")
    func restartReplaces() {
        var state = RestTimerState.start(seconds: 60, now: t0)
        state.tick(now: t0.addingTimeInterval(30))
        state = .start(seconds: 90, now: t0.addingTimeInterval(30))
        #expect(state.remainingSeconds == 90)
        #expect(state.progress == 0)
    }
}
