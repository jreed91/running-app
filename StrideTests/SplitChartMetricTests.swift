import Foundation
import Testing
@testable import Stride

/// Covers `SplitChartMetric`, the rule behind the splits card's tab row. N22 made those
/// tabs real, which turned "does this run carry per-split heart rate or elevation?" into
/// something the UI depends on — so it moved out of the view (D1).
struct SplitChartMetricTests {

    private func split(
        _ km: Int,
        pace: Double = 300,
        heartRate: Double? = nil,
        elevation: Double = 0
    ) -> Split {
        Split(
            kilometer: km,
            paceSecondsPerKm: pace,
            heartRate: heartRate,
            elevationGainMeters: elevation,
            cumulativeDistanceMeters: Double(km) * 1_000
        )
    }

    // MARK: Availability

    @Test("Pace is always offered — a split exists because a boundary was timed")
    func paceIsAlwaysAvailable() {
        let metrics = SplitChartMetric.available(for: [split(1), split(2)])

        #expect(metrics == [.pace])
    }

    @Test("Heart rate is offered as soon as one split carries a reading")
    func heartRateNeedsOneSample() {
        // A strap picked up partway through the run still gives a chart worth drawing.
        let metrics = SplitChartMetric.available(for: [split(1), split(2, heartRate: 152)])

        #expect(metrics == [.pace, .heartRate])
    }

    @Test("A run recorded without a strap offers no heart-rate tab")
    func noHeartRateMeansNoTab() {
        let metrics = SplitChartMetric.available(for: [split(1), split(2), split(3)])

        #expect(!metrics.contains(.heartRate))
    }

    @Test("Elevation needs a non-zero gain, since flat and unrecorded both store zero")
    func elevationNeedsNonZeroGain() {
        #expect(SplitChartMetric.available(for: [split(1, elevation: 0)]) == [.pace])
        #expect(SplitChartMetric.available(for: [split(1, elevation: 12)]) == [.pace, .elevation])
    }

    @Test("A negative gain still counts as elevation data")
    func negativeGainCounts() {
        // A net-downhill split is real data; only an exact zero is ambiguous.
        #expect(SplitChartMetric.available(for: [split(1, elevation: -8)]).contains(.elevation))
    }

    @Test("Tabs are offered in a fixed order: pace, heart rate, elevation")
    func orderIsStable() {
        let metrics = SplitChartMetric.available(for: [split(1, heartRate: 150, elevation: 20)])

        #expect(metrics == [.pace, .heartRate, .elevation])
    }

    @Test("No splits means no metrics, which hides the card rather than drawing it empty")
    func noSplitsMeansNoMetrics() {
        #expect(SplitChartMetric.available(for: []).isEmpty)
    }

    // MARK: Resolution

    @Test("A selection the run supports is kept")
    func supportedSelectionIsKept() {
        let available: [SplitChartMetric] = [.pace, .heartRate]

        #expect(SplitChartMetric.resolved(selection: .heartRate, in: available) == .heartRate)
    }

    @Test("A selection the run cannot chart falls back instead of charting nothing")
    func unsupportedSelectionFallsBack() {
        // The tab is view state that outlives the run it was chosen on: pick HR on one
        // run, open a run recorded without a strap, and the chart would have no series.
        let available: [SplitChartMetric] = [.pace, .elevation]

        #expect(SplitChartMetric.resolved(selection: .heartRate, in: available) == .pace)
    }

    @Test("Resolution against an empty list yields pace rather than trapping")
    func emptyAvailabilityYieldsPace() {
        #expect(SplitChartMetric.resolved(selection: .elevation, in: []) == .pace)
    }

    // MARK: Presentation

    @Test("The heading names the runner's own distance unit")
    func headingUsesUnit() {
        #expect(SplitChartMetric.pace.heading(bucket: "km") == "Pace per km")
        #expect(SplitChartMetric.pace.heading(bucket: "mi") == "Pace per mi")
        #expect(SplitChartMetric.heartRate.heading(bucket: "km") == "Heart rate per km")
        #expect(SplitChartMetric.elevation.heading(bucket: "mi") == "Elevation per mi")
    }

    @Test("The heading names the bucket, not the unit, on a subdivided run")
    func headingNamesSubdividedBucket() {
        // A one-mile run is charted on tenths (N34), and "Pace per mi" over tenth-mile bars
        // would name a reading the chart is not showing.
        let bucket = SplitChartSeries.bucketLabel(fraction: 0.1, unit: .imperial)

        #expect(SplitChartMetric.pace.heading(bucket: bucket) == "Pace per 0.1 mi")
        #expect(SplitChartMetric.heartRate.heading(bucket: bucket) == "Heart rate per 0.1 mi")
    }

    @Test("Every metric has a tab title and a footnote")
    func everyMetricIsLabelled() {
        for metric in SplitChartMetric.allCases {
            #expect(!metric.tabTitle.isEmpty)
            #expect(!metric.footnote.isEmpty)
        }
    }
}
