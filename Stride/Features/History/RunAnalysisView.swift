import SwiftUI
import MapKit
import Charts

// MARK: - RunAnalysisView

/// The run as one timeline: pace, heart rate and elevation stacked on a shared distance
/// axis, with one finger moving a rule across all three, a readout of the moment under
/// it, and a marker on the map where the runner was.
///
/// Opened in place from the run screen's Breakdown list. It owns its state (the selection,
/// the resampled points) and writes nothing of `RunSummaryView`'s, so scrubbing never
/// re-runs the run screen's body (PR #338).
struct RunAnalysisView: View {
    let workout: RunWorkout

    @Environment(AppSettings.self) private var appSettings
    @State private var points: [RunAnalysis.Point] = []
    @State private var route: [CLLocationCoordinate2D] = []
    /// Metres along the run under the finger; `nil` when not scrubbing.
    @State private var selectedMeters: Double?

    private var unit: UnitPreference { appSettings.unitPreference }

    /// Whether a run has enough recorded detail for this page.
    static func isAvailable(for workout: RunWorkout) -> Bool {
        workout.distanceSeriesData != nil && workout.distanceMeters >= 200
    }

    var body: some View {
        let selected = selectedMeters.flatMap { RunAnalysis.point(nearest: $0, in: points) }
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            readout(selected)
            if !route.isEmpty {
                map(selected)
            }
            if points.isEmpty {
                Text("This run didn't record enough detail to chart.")
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
            } else {
                charts(selected)
            }
            Text(selected == nil
                 ? "Touch and drag on a chart to follow the run."
                 : "Lift your finger to see the whole run again.")
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
        }
        .task(id: workout.id) {
            let readings = workout.distanceSeries.map {
                RunAnalysis.Reading(
                    elapsedSeconds: $0.elapsedSeconds,
                    meters: $0.cumulativeMeters,
                    altitudeMeters: $0.altitudeMeters
                )
            }
            points = RunAnalysis.points(
                readings: readings,
                heartRateSamples: workout.heartRateSamples,
                durationSeconds: workout.durationSeconds
            )
            route = workout.routeCoordinates.map(\.clCoordinate)
        }
    }

    // MARK: Readout

    /// The moment under the finger, or the whole run's figures when nobody is scrubbing.
    private func readout(_ point: RunAnalysis.Point?) -> some View {
        HStack(spacing: 0) {
            cell(
                point.map { $0.meters.distanceString(unit: unit) } ?? workout.distanceMeters.distanceString(unit: unit),
                "Distance"
            )
            cell(
                point.map { $0.elapsedSeconds.durationString } ?? workout.durationSeconds.durationString,
                "Time"
            )
            cell(
                (point?.paceSecondsPerKm ?? (point == nil ? workout.averagePaceSecondsPerKm : nil))
                    .map { $0.paceValueString(unit: unit) } ?? "--",
                "Pace"
            )
            cell(
                (point?.heartRate ?? (point == nil ? workout.averageHeartRate : nil))
                    .map { "\(Int($0.rounded()))" } ?? "--",
                "Heart rate"
            )
        }
        .padding(AppSpacing.lg)
        .heroCard()
        .accessibilityElement(children: .combine)
    }

    private func cell(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.dsTitle3.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.captionStrong)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Map

    private func map(_ point: RunAnalysis.Point?) -> some View {
        let marker = point.flatMap {
            RunAnalysis.routeIndex(
                atElapsed: $0.elapsedSeconds,
                duration: workout.durationSeconds,
                coordinateCount: route.count
            )
        }.map { route[$0] }
        return Map(interactionModes: [.zoom, .pan]) {
            MapPolyline(coordinates: route)
                .stroke(.route, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let start = route.first {
                Annotation("Start", coordinate: start, anchor: .center) {
                    StartPin(diameter: 14)
                }
                .annotationTitles(.hidden)
            }
            if let marker {
                Annotation("You", coordinate: marker, anchor: .center) {
                    Circle()
                        .fill(Color.brand)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.onFill, lineWidth: 3))
                        .appShadow(.e2)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(emphasis: .muted))
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .accessibilityLabel("Route map")
    }

    // MARK: Charts

    private func charts(_ selected: RunAnalysis.Point?) -> some View {
        let hasHeartRate = points.contains { $0.heartRate != nil }
        let hasElevation = points.contains { $0.altitudeMeters != nil }
        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            chartTitle("Pace")
            paceChart(selected)
            if hasHeartRate {
                chartTitle("Heart rate")
                heartRateChart(selected)
            }
            if hasElevation {
                chartTitle("Elevation")
                elevationChart(selected)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strideCard()
    }

    private func chartTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .strideEyebrow()
            .foregroundStyle(.secondary)
    }

    private func paceChart(_ selected: RunAnalysis.Point?) -> some View {
        Chart {
            ForEach(points) { point in
                if let pace = point.paceSecondsPerKm {
                    LineMark(x: .value("Distance", distance(point.meters)), y: .value("Pace", pace))
                        .foregroundStyle(.route)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            if workout.averagePaceSecondsPerKm > 0 {
                RuleMark(y: .value("Average", workout.averagePaceSecondsPerKm))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            selectionRule(selected)
        }
        .frame(height: 140)
        .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self), seconds > 0 {
                        Text(seconds.paceValueString(unit: unit))
                    }
                }
            }
        }
        .modifier(SharedDistanceAxis(selection: $selectedMeters, unit: unit))
        .chartAccessibility("Pace along the run", series(\.paceSecondsPerKm, "Pace") { $0.paceString(unit: unit) })
    }

    private func heartRateChart(_ selected: RunAnalysis.Point?) -> some View {
        Chart {
            ForEach(points) { point in
                if let heartRate = point.heartRate {
                    AreaMark(x: .value("Distance", distance(point.meters)), y: .value("Heart rate", heartRate))
                        .foregroundStyle(Color.zoneInterval.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Distance", distance(point.meters)), y: .value("Heart rate", heartRate))
                        .foregroundStyle(Color.zoneInterval)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            selectionRule(selected)
        }
        .frame(height: 110)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
        }
        .modifier(SharedDistanceAxis(selection: $selectedMeters, unit: unit))
        .chartAccessibility("Heart rate along the run", series(\.heartRate, "Heart rate") { "\(Int($0)) bpm" })
    }

    private func elevationChart(_ selected: RunAnalysis.Point?) -> some View {
        Chart {
            ForEach(points) { point in
                if let altitude = point.altitudeMeters {
                    AreaMark(
                        x: .value("Distance", distance(point.meters)),
                        yStart: .value("Floor", elevationFloor),
                        yEnd: .value("Elevation", altitude.elevationValue(unit: unit))
                    )
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .interpolationMethod(.monotone)
                }
            }
            selectionRule(selected)
        }
        .frame(height: 90)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
        }
        .modifier(SharedDistanceAxis(selection: $selectedMeters, unit: unit))
        .chartAccessibility("Elevation along the run", series(\.altitudeMeters, "Elevation") {
            $0.elevationString(unit: unit)
        })
    }

    /// The bottom of the elevation fill: just under the lowest point, so the profile
    /// isn't a thin strip on top of a tall block.
    private var elevationFloor: Double {
        let lowest = points.compactMap(\.altitudeMeters).min() ?? 0
        return (lowest - 5).elevationValue(unit: unit)
    }

    @ChartContentBuilder
    private func selectionRule(_ selected: RunAnalysis.Point?) -> some ChartContent {
        if let selected {
            RuleMark(x: .value("Distance", distance(selected.meters)))
                .foregroundStyle(Color.brand.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    private func distance(_ meters: Double) -> Double {
        meters.distanceValue(unit: unit)
    }

    /// One point per tenth of the run is plenty to hear its shape.
    private func series(
        _ value: KeyPath<RunAnalysis.Point, Double?>,
        _ label: String,
        format: @escaping (Double) -> String
    ) -> ChartAccessibility.Series {
        let every = max(1, points.count / 10)
        let sampled = points.enumerated().filter { $0.offset % every == 0 }.map(\.element)
        return ChartAccessibility.Series(
            points: sampled.compactMap { point in
                point[keyPath: value].map {
                    ChartAccessibility.Point(label: point.meters.distanceString(unit: unit), value: $0)
                }
            },
            valueAxisLabel: label,
            format: format
        )
    }
}

// MARK: - Shared axis

/// The x axis every chart on the page shares: distance in the runner's unit, and the
/// one selection binding, so a drag on any chart moves the rule on all of them.
private struct SharedDistanceAxis: ViewModifier {
    @Binding var selection: Double?
    let unit: UnitPreference

    func body(content: Content) -> some View {
        content
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(String(format: "%.0f %@", number, unit.distanceLabel))
                        }
                    }
                }
            }
            .chartXSelection(value: metersBinding)
    }

    /// The charts plot km or miles; the page keeps metres.
    private var metersBinding: Binding<Double?> {
        Binding(
            get: { selection.map { $0.distanceValue(unit: unit) } },
            set: { newValue in
                selection = newValue.map { unit == .metric ? $0 * 1_000 : $0 * 1_609.344 }
            }
        )
    }
}
