import Foundation
import Testing
@testable import Stride

// MARK: - Watch auto-pause tests

struct WatchAutoPauseTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func time(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test("Standing still for 6 s pauses, and moving for 3 s resumes")
    func pausesAndResumes() {
        var auto = WatchAutoPause()
        let moving = auto.update(speed: 3, at: time(0), isRunning: true)
        let stopping = auto.update(speed: 0.2, at: time(1), isRunning: true)
        let stillWaiting = auto.update(speed: 0.1, at: time(6), isRunning: true)
        let paused = auto.update(speed: 0, at: time(7), isRunning: true)
        #expect(moving == nil)
        #expect(stopping == nil)
        #expect(stillWaiting == nil)
        #expect(paused == .pause)
        #expect(auto.isAutoPaused)

        // The workout is paused now, so the recorder passes isRunning false.
        let firstStep = auto.update(speed: 2, at: time(10), isRunning: false)
        let resumed = auto.update(speed: 2.5, at: time(13), isRunning: false)
        #expect(firstStep == nil)
        #expect(resumed == .resume)
        #expect(!auto.isAutoPaused)
    }

    @Test("A slow shuffle between the two speeds neither pauses nor resumes")
    func shuffleIsIgnored() {
        var auto = WatchAutoPause()
        _ = auto.update(speed: 0.2, at: time(0), isRunning: true)
        let shuffle = auto.update(speed: 0.8, at: time(4), isRunning: true)
        let later = auto.update(speed: 0.2, at: time(8), isRunning: true)
        #expect(shuffle == nil)
        // The shuffle broke the stop, so the 6 s count started again at 8 s.
        #expect(later == nil)
    }

    @Test("A pause made by hand is never resumed by moving")
    func manualPauseStays() {
        var auto = WatchAutoPause()
        _ = auto.update(speed: 3, at: time(0), isRunning: false)
        let moving = auto.update(speed: 3, at: time(5), isRunning: false)
        #expect(moving == nil)
    }

    @Test("Unknown speed changes nothing")
    func unknownSpeed() {
        var auto = WatchAutoPause()
        _ = auto.update(speed: 0, at: time(0), isRunning: true)
        let unknown = auto.update(speed: -1, at: time(3), isRunning: true)
        let paused = auto.update(speed: 0, at: time(6), isRunning: true)
        #expect(unknown == nil)
        #expect(paused == .pause)
    }
}
