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

    // MARK: Chart scale

    @Test("The chart domain is centred on the average and fits the furthest split with headroom")
    func chartDomainFitsData() {
        let domain = SplitPaceStats.chartDomain(paces: [280, 300, 340], average: 300)

        // Furthest is 40 s off; 15% headroom makes the half-range 46.
        #expect(abs(domain.lowerBound - 254) < 0.0001)
        #expect(abs(domain.upperBound - 346) < 0.0001)
    }

    @Test("An even run keeps the minimum range, so a few seconds of noise stay small")
    func chartDomainHasAFloor() {
        let domain = SplitPaceStats.chartDomain(paces: [299, 300, 302], average: 300)

        #expect(domain == 285...315)
    }

    @Test("A stopped split cannot stretch the chart past the maximum range")
    func chartDomainHasACeiling() {
        // A quarter mile with a stop in it: 800 s/km against a 400 s/km average. Fitting it
        // drew the 5:21-21:27 axis seen on device.
        let domain = SplitPaceStats.chartDomain(paces: [390, 400, 410, 800], average: 400)

        #expect(domain == 310...490)
        #expect(SplitPaceStats.clamped(800, to: domain) == 490)
        #expect(SplitPaceStats.clamped(395, to: domain) == 395)
        #expect(SplitPaceStats.clamped(100, to: domain) == 310)
    }

    @Test("Unusable paces do not widen the chart")
    func chartDomainIgnoresUnusablePaces() {
        let domain = SplitPaceStats.chartDomain(paces: [0, .infinity, 300], average: 300)

        #expect(domain == 285...315)
    }

    // MARK: Run shape

    @Test("Halves within the tolerance read as even")
    func shapeEven() {
        let splits = [paceSplit(1, 300), paceSplit(2, 302), paceSplit(3, 301), paceSplit(4, 303)]

        #expect(SplitPaceStats.shape(splits, unit: .metric) == .even)
        #expect(SplitPaceStats.shapeHeadline(.even, unit: .metric) == "Even pace start to finish")
    }

    @Test("A slower second half is reported per display unit")
    func shapeSlowerFinish() {
        // First half averages 300, second 320: 20 s/km, 32 s/mi.
        let splits = [paceSplit(1, 300), paceSplit(2, 300), paceSplit(3, 320), paceSplit(4, 320)]

        #expect(SplitPaceStats.shape(splits, unit: .metric) == .slowerFinish(seconds: 20))
        #expect(SplitPaceStats.shape(splits, unit: .imperial) == .slowerFinish(seconds: 32))
        #expect(
            SplitPaceStats.shapeHeadline(.slowerFinish(seconds: 32), unit: .imperial)
                == "Second half 32s/mi slower"
        )
    }

    @Test("A faster second half reads as a faster finish, and an odd middle split is left out")
    func shapeFasterFinish() {
        // The 900 s/km middle split belongs to neither half.
        let splits = [paceSplit(1, 310), paceSplit(2, 900), paceSplit(3, 300)]

        #expect(SplitPaceStats.shape(splits, unit: .metric) == .fasterFinish(seconds: 10))
        #expect(
            SplitPaceStats.shapeHeadline(.fasterFinish(seconds: 10), unit: .metric)
                == "Second half 10s/km faster"
        )
    }

    @Test("Fewer than two usable splits have no shape")
    func shapeNeedsTwoSplits() {
        #expect(SplitPaceStats.shape([paceSplit(1, 300)], unit: .metric) == nil)
        #expect(SplitPaceStats.shape([paceSplit(1, 300), paceSplit(2, 0)], unit: .metric) == nil)
    }
}
