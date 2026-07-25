import Testing
import Foundation
@testable import Stride

private func paceSplit(_ index: Int, _ pace: Double) -> Split {
    Split(
        kilometer: index,
        paceSecondsPerKm: pace,
        heartRate: nil,
        elevationGainMeters: 0,
        cumulativeDistanceMeters: Double(index) * 1_000
    )
}

struct SplitPaceStatsTests {

    @Test("Average split pace is the mean of the splits that recorded one")
    func averagePace() throws {
        let splits = [paceSplit(1, 300), paceSplit(2, 310), paceSplit(3, 320)]

        let average = try #require(SplitPaceStats.averagePaceSecondsPerKm(splits))

        #expect(average == 310)
    }

    @Test("Splits without a usable pace are left out of the average")
    func averageIgnoresUnusablePaces() throws {
        let splits = [paceSplit(1, 0), paceSplit(2, 300), paceSplit(3, 320), paceSplit(4, .infinity)]

        let average = try #require(SplitPaceStats.averagePaceSecondsPerKm(splits))

        #expect(average == 310)
        #expect(SplitPaceStats.averagePaceSecondsPerKm([]) == nil)
        #expect(SplitPaceStats.averagePaceSecondsPerKm([paceSplit(1, 0)]) == nil)
    }

    @Test("A faster split reads as a negative delta, a slower one as positive")
    func deltaSign() {
        #expect(SplitPaceStats.deltaSeconds(pace: 290, average: 300, unit: .metric) == -10)
        #expect(SplitPaceStats.deltaSeconds(pace: 312, average: 300, unit: .metric) == 12)
    }

    @Test("Deltas are expressed per display unit")
    func deltaConvertsToDisplayUnit() {
        let metric = SplitPaceStats.deltaSeconds(pace: 310, average: 300, unit: .metric)
        let imperial = SplitPaceStats.deltaSeconds(pace: 310, average: 300, unit: .imperial)

        #expect(metric == 10)
        #expect(abs(imperial - 16.0934) < 0.0001)
    }

    @Test("Splits inside the tolerance read as on-pace, outside it as faster or slower")
    func comparisonThresholds() {
        #expect(SplitPaceStats.comparison(pace: 300, average: 300, unit: .metric) == .onPace)
        #expect(SplitPaceStats.comparison(pace: 298, average: 300, unit: .metric) == .onPace)
        #expect(SplitPaceStats.comparison(pace: 302, average: 300, unit: .metric) == .onPace)
        #expect(SplitPaceStats.comparison(pace: 297, average: 300, unit: .metric) == .faster)
        #expect(SplitPaceStats.comparison(pace: 303, average: 300, unit: .metric) == .slower)
    }

    @Test("The tolerance applies to the pace the runner sees, so miles classify sooner")
    func comparisonUsesDisplayUnit() {
        // 2 s/km is inside the tolerance, but the same gap is 3.2 s/mi — which is what an
        // imperial runner reads off the chart.
        #expect(SplitPaceStats.comparison(pace: 302, average: 300, unit: .metric) == .onPace)
        #expect(SplitPaceStats.comparison(pace: 302, average: 300, unit: .imperial) == .slower)
    }

    @Test("Delta labels name the direction and round to whole seconds")
    func deltaLabels() {
        #expect(SplitPaceStats.deltaLabel(pace: 288, average: 300, unit: .metric) == "12s faster than avg")
        #expect(SplitPaceStats.deltaLabel(pace: 305, average: 300, unit: .metric) == "5s slower than avg")
        #expect(SplitPaceStats.deltaLabel(pace: 300, average: 300, unit: .metric) == "on average pace")
        // Rounds to zero rather than claiming a 0-second difference in either direction.
        #expect(SplitPaceStats.deltaLabel(pace: 300.3, average: 300, unit: .metric) == "on average pace")
    }
}
