import SwiftUI
import Accessibility

extension View {
    /// Collapses a chart into a single labelled accessibility element that speaks a
    /// summary of its data (N18).
    ///
    /// Left alone, a `Chart`'s marks are exposed as unlabelled sub-elements, so a
    /// VoiceOver user swiping through the Progress tab or a run's splits hears a series of
    /// bare numbers with nothing saying which chart they belong to — and a chart carrying
    /// a `chartXSelection` overlay often exposes nothing at all.
    ///
    /// Build `summary` with ``ChartAccessibility/summary(_:format:)`` so every chart in the
    /// app describes itself the same way. Prefer the ``ChartAccessibility/Series``
    /// overload where the points are to hand: it speaks the identical summary *and* makes
    /// the chart playable as an Audio Graph.
    func chartAccessibility(_ label: String, _ summary: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(summary)
    }

    /// The same collapsed element, plus an **Audio Graph** (U10).
    ///
    /// Collapsing a chart into one summary sentence is the right default — it is quick to
    /// hear and comparable between charts — but it is also the whole chart, gone: a
    /// VoiceOver user could not reach an individual point. `accessibilityChartDescriptor`
    /// restores that without touching the visual chart or the spoken summary: VoiceOver
    /// offers "Describe Chart" and "Play Audio Graph", which sonifies the series and lets
    /// the user step through it value by value.
    func chartAccessibility(_ label: String, _ series: ChartAccessibility.Series) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(series.summary)
            .accessibilityChartDescriptor(StrideChartDescriptor(title: label, series: series))
    }
}

// MARK: - StrideChartDescriptor

/// Bridges a ``ChartAccessibility/Series`` to the `AXChartDescriptor` that drives Audio
/// Graphs.
///
/// Every chart in the app is a series of values measured *at* something — a date, a split
/// number, a heart-rate zone — which the summary already renders as a label. So the x-axis
/// is categorical rather than numeric: it uses those same labels, in the order the chart
/// draws them, and no chart has to describe its axis twice.
struct StrideChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let series: ChartAccessibility.Series

    func makeChartDescriptor() -> AXChartDescriptor {
        let points = series.points
        let values = points.map(\.value)
        let format = series.format

        let xAxis = AXCategoricalDataAxisDescriptor(
            title: title,
            categoryOrder: points.map(\.label)
        )

        // An empty chart still needs a range: `AXNumericDataAxisDescriptor` takes a
        // `ClosedRange`, which cannot be built from `min > max`.
        let lowerBound = values.min() ?? 0
        let upperBound = max(values.max() ?? 0, lowerBound)
        let yAxis = AXNumericDataAxisDescriptor(
            title: series.valueAxisLabel,
            range: lowerBound...upperBound,
            gridlinePositions: []
        ) { value in
            format(value)
        }

        let dataSeries = AXDataSeriesDescriptor(
            name: title,
            // The x-axis is categorical, so the series is a set of discrete readings
            // rather than a continuous function to be interpolated between.
            isContinuous: false,
            dataPoints: points.map { AXDataPoint(x: $0.label, y: $0.value) }
        )

        return AXChartDescriptor(
            title: title,
            summary: series.summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [dataSeries]
        )
    }

    /// Nothing to update in place: the descriptor is rebuilt from the series whenever the
    /// data changes, which is the cheaper of the two paths for charts this small.
    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}
}
