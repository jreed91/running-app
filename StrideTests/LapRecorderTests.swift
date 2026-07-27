import Testing
import Foundation
@testable import Stride

// MARK: - LapRecorder tests (A2 — manual laps)
//
// The lap boundary → `Lap` mapping: numbering, the implicit opening boundary, the final
// lap closed by the finish, and the degenerate inputs a tapped control produces.

struct LapRecorderTests {

    private func mark(_ seconds: Double, _ meters: Double) -> LapRecorder.Mark {
        LapRecorder.Mark(elapsedSeconds: seconds, distanceMeters: meters)
    }

    // MARK: An unlapped run

    @Test("A run with no marks has no laps at all")
    func noMarksNoLaps() {
        #expect(LapRecorder.laps(marks: [], finish: mark(1_800, 6_000)).isEmpty)
        #expect(LapRecorder.closedLaps(marks: []).isEmpty)
    }

    // MARK: Numbering and boundaries

    @Test("Laps run from the start, between the marks, and on to the finish")
    func lapsSpanEveryBoundary() {
        let laps = LapRecorder.laps(
            marks: [mark(300, 1_000), mark(600, 2_000)],
            finish: mark(900, 3_000)
        )
        #expect(laps.count == 3)
        #expect(laps.map(\.number) == [1, 2, 3])
        #expect(laps.map(\.startElapsedSeconds) == [0, 300, 600])
        #expect(laps.allSatisfy { $0.durationSeconds == 300 })
        #expect(laps.allSatisfy { $0.distanceMeters == 1_000 })
    }

    @Test("Closed laps exclude the one still in progress")
    func closedLapsStopAtTheLastMark() {
        let marks = [mark(300, 1_000), mark(600, 2_000)]
        let closed = LapRecorder.closedLaps(marks: marks)
        #expect(closed.count == 2)
        #expect(closed.map(\.number) == [1, 2])
        // The runner is on lap 3; it has no end yet, so it is not one of these.
        #expect(closed.last?.startElapsedSeconds == 300)
    }

    // MARK: Pace

    @Test("A lap's pace is its own time over its own distance")
    func lapPaceIsPerLap() throws {
        // 1 000 m in 300 s → 5:00 /km, regardless of how the rest of the run went.
        let laps = LapRecorder.laps(marks: [mark(300, 1_000)], finish: mark(1_200, 2_000))
        #expect(laps.count == 2)
        #expect(abs(laps[0].paceSecondsPerKm - 300) < 0.001)
        // Second lap: 1 000 m in 900 s → 15:00 /km.
        #expect(abs(laps[1].paceSecondsPerKm - 900) < 0.001)
    }

    @Test("A lap that covered no distance reports no pace rather than an infinite one")
    func standingStillLapHasZeroPace() {
        let laps = LapRecorder.laps(marks: [mark(60, 0)], finish: mark(120, 0))
        #expect(laps.count == 2)
        #expect(laps.allSatisfy { $0.paceSecondsPerKm == 0 })
        #expect(laps.allSatisfy { $0.distanceMeters == 0 })
    }

    // MARK: Degenerate input

    @Test("A double-tap inside one tick is dropped and numbering stays contiguous")
    func zeroDurationLapsAreDropped() {
        let laps = LapRecorder.laps(
            marks: [mark(300, 1_000), mark(300, 1_000), mark(600, 2_000)],
            finish: mark(900, 3_000)
        )
        // The zero-length lap between the duplicated marks is gone, and the survivors are
        // still 1…n with no hole where it was.
        #expect(laps.count == 3)
        #expect(laps.map(\.number) == [1, 2, 3])
        #expect(laps.allSatisfy { $0.durationSeconds == 300 })
    }

    @Test("Distance that fails to advance is clamped rather than going negative")
    func distanceNeverGoesNegative() throws {
        // A rejected GPS fix or an indoor resume can leave the total where it was, or
        // briefly behind it; a lap must never claim negative ground.
        let laps = LapRecorder.laps(marks: [mark(300, 1_000)], finish: mark(600, 900))
        let last = try #require(laps.last)
        #expect(last.distanceMeters == 0)
        #expect(last.paceSecondsPerKm == 0)
    }

    @Test("A finish that lands on the last mark adds no empty final lap")
    func finishOnTheLastMarkAddsNothing() {
        let laps = LapRecorder.laps(marks: [mark(300, 1_000)], finish: mark(300, 1_000))
        #expect(laps.count == 1)
        #expect(laps[0].number == 1)
    }
}
