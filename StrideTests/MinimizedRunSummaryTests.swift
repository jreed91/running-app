import Testing
import Foundation
@testable import Stride

// MARK: - What a minimised run says (U7)
//
// The tab-bar accessory is one line and is all a runner sees of a recording run while
// they are elsewhere in the app, so the wording is load-bearing: it has to state the
// paused condition in words rather than leave it to the glyph beside it (U3d), and it
// has to read as a sentence to VoiceOver rather than as "27:14 dot 5.4 k m".

struct MinimizedRunSummaryTests {

    // 27:14 into a run, 5.4 km in.
    private let elapsed: Double = 1_634
    private let distance: Double = 5_400

    // MARK: Title

    @Test("A recording run shows elapsed time and distance")
    func activeTitle() {
        let title = MinimizedRunSummary.title(
            state: .active,
            elapsedSeconds: elapsed,
            distanceMeters: distance,
            unit: .metric
        )
        #expect(title == "27:14 · 5.4 km")
    }

    @Test("A paused run says so in words, and still shows the run")
    func pausedTitle() {
        let title = MinimizedRunSummary.title(
            state: .paused,
            elapsedSeconds: elapsed,
            distanceMeters: distance,
            unit: .metric
        )
        #expect(title == "Paused · 27:14 · 5.4 km")
    }

    @Test("The distance is in the runner's own unit")
    func imperialTitle() {
        let title = MinimizedRunSummary.title(
            state: .active,
            elapsedSeconds: elapsed,
            distanceMeters: distance,
            unit: .imperial
        )
        // 5,400 m ≈ 3.36 mi.
        #expect(title == "27:14 · 3.4 mi")
    }

    @Test("A run that hasn't started yet is not described as paused")
    func idleTitleIsNotPaused() {
        let title = MinimizedRunSummary.title(
            state: .idle,
            elapsedSeconds: 0,
            distanceMeters: 0,
            unit: .metric
        )
        #expect(title == "0:00 · 0.0 km")
    }

    // MARK: Spoken label

    @Test("VoiceOver hears the status, the elapsed time, and a spelled-out unit")
    func activeSpokenLabel() {
        let spoken = MinimizedRunSummary.spokenLabel(
            state: .active,
            elapsedSeconds: elapsed,
            distanceMeters: distance,
            unit: .metric
        )
        #expect(spoken == "Run in progress. 27:14 elapsed, 5.4 kilometres")
    }

    @Test("The paused state reaches VoiceOver too, not just the screen")
    func pausedSpokenLabel() {
        let spoken = MinimizedRunSummary.spokenLabel(
            state: .paused,
            elapsedSeconds: elapsed,
            distanceMeters: distance,
            unit: .metric
        )
        #expect(spoken == "Run paused. 27:14 elapsed, 5.4 kilometres")
    }

    @Test("An imperial runner hears miles, spelled out")
    func imperialSpokenLabel() {
        let spoken = MinimizedRunSummary.spokenLabel(
            state: .active,
            elapsedSeconds: elapsed,
            distanceMeters: distance,
            unit: .imperial
        )
        #expect(spoken == "Run in progress. 27:14 elapsed, 3.4 miles")
    }
}
