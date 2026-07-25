import Foundation
import Testing
@testable import Stride

/// Covers the spoken summary every chart in the app now carries (N18): a `Chart`'s marks
/// are otherwise unlabelled, so VoiceOver read them as anonymous numbers or not at all.
struct ChartAccessibilityTests {

    private func point(_ label: String, _ value: Double) -> ChartAccessibility.Point {
        ChartAccessibility.Point(label: label, value: value)
    }

    @Test("An empty chart says so rather than speaking an empty string")
    func emptySeriesSaysNoData() {
        let summary = ChartAccessibility.summary([]) { "\($0)" }
        #expect(summary == "No data")
    }

    @Test("A single value is spoken on its own, without endpoints or extremes")
    func singleValue() {
        let summary = ChartAccessibility.summary([point("Mar 2", 42)]) { "\(Int($0)) km" }
        #expect(summary == "1 value: Mar 2, 42 km.")
    }

    @Test("A series is spoken as count, endpoints, then extremes")
    func seriesSummary() {
        let summary = ChartAccessibility.summary(
            [point("Mar 2", 5), point("Mar 9", 12), point("Mar 16", 8)]
        ) { "\(Int($0)) km" }

        #expect(summary == "3 values. From Mar 2, 5 km to Mar 16, 8 km. "
            + "Lowest Mar 2, 5 km. Highest Mar 9, 12 km.")
    }

    /// Endpoints are read in the order the chart draws them, not sorted by value —
    /// "from … to …" only means anything along the chart's own axis.
    @Test("Endpoints follow plotting order, not magnitude")
    func endpointsFollowPlottingOrder() {
        let summary = ChartAccessibility.summary(
            [point("km 1", 300), point("km 2", 280)]
        ) { $0.paceString(unit: .metric) }

        #expect(summary.contains("From km 1, 5:00 min/km to km 2, 4:40 min/km."))
    }

    /// A flat series has no meaningful low and high, so naming them twice more would be
    /// noise on top of the endpoints that already said the value.
    @Test("A flat series omits the extremes")
    func flatSeriesOmitsExtremes() {
        let summary = ChartAccessibility.summary(
            [point("Z1", 60), point("Z2", 60)]
        ) { "\(Int($0)) minutes" }

        #expect(summary == "2 values. From Z1, 60 minutes to Z2, 60 minutes.")
    }

    @Test("Formatting is the caller's, so each chart speaks its own units")
    func formattingIsCallerSupplied() {
        let points = [point("Mar 2", 150), point("Mar 9", 162)]
        let bpm = ChartAccessibility.summary(points) { "\(Int($0)) beats per minute" }
        #expect(bpm.contains("150 beats per minute"))
        #expect(bpm.contains("162 beats per minute"))
    }
}
