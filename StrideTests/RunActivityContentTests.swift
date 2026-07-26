import Testing
import Foundation
@testable import Stride

// MARK: - What the run's Live Activity shows (U5b)
//
// The Lock Screen's numbers are formatted by the app, not by the widget, so they are
// testable here — and two of them are easy to get subtly wrong. The elapsed *interval* is
// derived backwards from elapsed time, because an activity is refreshed mid-run and a
// resumed run has banked time; and the paused case has to freeze that interval at exactly
// the elapsed time rather than at zero.

struct RunActivityContentTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        elapsed: Double = 1_634,
        distance: Double = 5_400,
        pace: Double = 272,
        isPaused: Bool = false,
        unit: UnitPreference = .metric
    ) -> RunActivitySnapshot {
        RunActivitySnapshot(
            elapsedSeconds: elapsed,
            distanceMeters: distance,
            paceSecondsPerKm: pace,
            isPaused: isPaused,
            unit: unit,
            workoutType: .tempo
        )
    }

    // MARK: Figures

    @Test("Distance and pace are formatted in the runner's own unit")
    func metricFigures() {
        let state = RunActivityContent.state(from: snapshot(), now: now)
        #expect(state.distance == "5.4 km")
        #expect(state.pace == "4:32 /km")
    }

    @Test("An imperial runner's card is in miles")
    func imperialFigures() {
        let state = RunActivityContent.state(from: snapshot(unit: .imperial), now: now)
        #expect(state.distance == "3.4 mi")
        // 272 s/km ≈ 437 s/mi = 7:17.
        #expect(state.pace == "7:17 /mi")
    }

    @Test("Before the first pace reading the card shows no pace at all")
    func noPaceYet() {
        let state = RunActivityContent.state(from: snapshot(pace: 0), now: now)
        #expect(state.pace == nil)
        // The distance is still shown — it is 0.0, not unknown.
        #expect(state.distance == "5.4 km")
    }

    // MARK: The clock

    @Test("The clock's interval starts where the run's elapsed time puts it, not at `now`")
    func clockStartsFromElapsedTime() {
        let state = RunActivityContent.state(from: snapshot(elapsed: 1_634), now: now)
        // 27:14 ago. This is what lets an activity started or refreshed mid-run show the
        // right number without the app pushing one update a second.
        #expect(state.elapsed.lowerBound == now.addingTimeInterval(-1_634))
        #expect(state.elapsed.upperBound == state.elapsed.lowerBound
            .addingTimeInterval(RunActivityContent.clockSpan))
    }

    @Test("A run at zero seconds starts its clock at now")
    func clockAtRunStart() {
        let state = RunActivityContent.state(from: snapshot(elapsed: 0, distance: 0), now: now)
        #expect(state.elapsed.lowerBound == now)
    }

    // MARK: Pausing

    @Test("A paused run freezes the clock exactly where the run stopped")
    func pausedFreezesAtElapsed() {
        let state = RunActivityContent.state(from: snapshot(elapsed: 1_634, isPaused: true), now: now)
        #expect(state.isPaused)
        // Frozen at `now`, over an interval that began 27:14 earlier — so the card reads
        // 27:14 and stays there, rather than freezing at zero or carrying on.
        #expect(state.pausedAt == now)
        #expect(state.pausedAt?.timeIntervalSince(state.elapsed.lowerBound) == 1_634)
    }

    @Test("A running run has no pause time, so the widget counts it")
    func runningHasNoPauseTime() {
        let state = RunActivityContent.state(from: snapshot(), now: now)
        #expect(state.pausedAt == nil)
        #expect(!state.isPaused)
    }

    // MARK: Deep link

    @Test("The card's deep link is the one the app resolves")
    func deepLink() {
        let url = RunActivityDeepLink.activeRun
        #expect(url?.scheme == RunActivityDeepLink.scheme)
        #expect(url?.host == RunActivityDeepLink.activeRunHost)
        #expect(url?.absoluteString == "stride://active-run")
    }
}
