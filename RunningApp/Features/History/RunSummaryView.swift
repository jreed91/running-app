import SwiftUI
import MapKit
import Charts
import SwiftData

struct RunSummaryView: View {
    let workout: RunWorkout

    @Environment(AppSettings.self) private var appSettings
    @Query private var scheduledWorkouts: [ScheduledWorkout]

    private var matchedScheduled: ScheduledWorkout? {
        scheduledWorkouts.first { $0.completedWorkout?.id == workout.id }
    }

    private var estimatedVO2Max: Double? {
        guard workout.distanceMeters >= 400, workout.durationSeconds > 0 else { return nil }
        let v = PaceCalculatorService.vdot(distanceMeters: workout.distanceMeters, timeSeconds: workout.durationSeconds)
        return v > 0 ? v : nil
    }

    private var hasSplitHR: Bool {
        workout.splits.contains { $0.heartRate != nil }
    }

    private var hasSplitElevation: Bool {
        workout.splits.contains { $0.elevationGainMeters != 0 }
    }

    private var elevationUnit: String {
        appSettings.unitPreference == .metric ? "m" : "ft"
    }

    private func elevationDisplay(_ meters: Double) -> Double {
        appSettings.unitPreference == .metric ? meters : meters * 3.28084
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                routeMap
                statsGrid
                performanceFeedbackSection
                if !workout.splits.isEmpty {
                    splitPaceChart
                    if hasSplitHR { splitHRChart }
                    if hasSplitElevation { splitElevationChart }
                    splitsTable
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(workout.workoutType.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Route map

    private var routeMap: some View {
        Group {
            if workout.routeCoordinates.isEmpty {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.surfaceSecondary)
                    .frame(height: 220)
                    .overlay { Label("No route data", systemImage: "map") }
            } else {
                Map {
                    MapPolyline(coordinates: workout.routeCoordinates.map(\.clCoordinate))
                        .stroke(.brand, lineWidth: 4)
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: Stats grid

    private var statsGrid: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 16) {
            statCell(value: workout.distanceMeters.distanceString(unit: appSettings.unitPreference), label: "Distance")
            statCell(value: workout.durationSeconds.durationString, label: "Duration")
            statCell(
                value: workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference),
                label: "Avg Pace"
            )
            if let hr = workout.averageHeartRate {
                statCell(value: "\(Int(hr)) bpm", label: "Avg HR")
            }
            if let maxHR = workout.maxHeartRate {
                statCell(value: "\(Int(maxHR)) bpm", label: "Max HR")
            }
            if let gain = workout.elevationGainMeters {
                statCell(
                    value: appSettings.unitPreference == .metric
                        ? String(format: "+%.0f m", gain)
                        : String(format: "+%.0f ft", gain * 3.28084),
                    label: "Elevation"
                )
            }
            if let vo2 = estimatedVO2Max {
                statCell(value: String(format: "%.1f", vo2), label: "Est. VO₂ Max")
            }
        }
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.metricSmall)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Split pace chart

    private var splitPaceChart: some View {
        chartSection(title: "SPLIT PACES") {
            Chart(workout.splits, id: \.kilometer) { split in
                BarMark(
                    x: .value(appSettings.unitPreference.distanceLabel, split.kilometer),
                    y: .value("Pace", split.paceSecondsPerKm)
                )
                .foregroundStyle(.brand)
            }
            .frame(height: 120)
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let secs = value.as(Double.self) {
                            Text(secs.paceString(unit: appSettings.unitPreference)
                                .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: ""))
                        }
                    }
                }
            }
            Text("Lower = faster").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Split HR chart

    private var splitHRChart: some View {
        chartSection(title: "HEART RATE BY SPLIT") {
            Chart(workout.splits.filter { $0.heartRate != nil }, id: \.kilometer) { split in
                LineMark(
                    x: .value(appSettings.unitPreference.distanceLabel, split.kilometer),
                    y: .value("bpm", split.heartRate ?? 0)
                )
                .foregroundStyle(.zoneInterval)
                PointMark(
                    x: .value(appSettings.unitPreference.distanceLabel, split.kilometer),
                    y: .value("bpm", split.heartRate ?? 0)
                )
                .foregroundStyle(.zoneInterval)
            }
            .frame(height: 120)
            .chartYAxisLabel("bpm")
        }
    }

    // MARK: Split elevation chart

    private var splitElevationChart: some View {
        chartSection(title: "ELEVATION BY SPLIT") {
            Chart(workout.splits, id: \.kilometer) { split in
                BarMark(
                    x: .value(appSettings.unitPreference.distanceLabel, split.kilometer),
                    y: .value(elevationUnit, elevationDisplay(split.elevationGainMeters))
                )
                .foregroundStyle(elevationDisplay(split.elevationGainMeters) >= 0 ? Color.success : Color.destructive)
            }
            .frame(height: 100)
            .chartYAxisLabel(elevationUnit)
        }
    }

    // MARK: Splits table

    private var splitsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SPLITS").font(.sectionHeader).foregroundStyle(.secondary)
            HStack {
                Text(appSettings.unitPreference.distanceLabel.uppercased())
                    .frame(width: 36, alignment: .leading)
                Spacer()
                Text("PACE")
                if hasSplitHR {
                    Text("HR").frame(width: 60, alignment: .trailing)
                }
                Text("ELEV").frame(width: 60, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(workout.splits, id: \.kilometer) { split in
                splitRow(split)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func splitRow(_ split: Split) -> some View {
        HStack {
            Text("\(split.kilometer)")
                .frame(width: 36, alignment: .leading)
                .font(.bodyRegular)
            Spacer()
            Text(split.paceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                .font(.bodyStrong)
            if hasSplitHR {
                Group {
                    if let hr = split.heartRate {
                        Text("\(Int(hr))").foregroundStyle(.zoneInterval)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 60, alignment: .trailing)
                .font(.caption)
            }
            elevationCell(split.elevationGainMeters)
                .frame(width: 60, alignment: .trailing)
                .font(.caption)
        }
    }

    @ViewBuilder
    private func elevationCell(_ meters: Double) -> some View {
        if meters != 0 {
            let g = elevationDisplay(meters)
            Text("\(g >= 0 ? "+" : "")\(Int(g))\(elevationUnit)")
                .foregroundStyle(g >= 0 ? Color.success : Color.destructive)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    // MARK: Chart section helper

    private func chartSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.sectionHeader).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Performance Feedback

    @ViewBuilder
    private var performanceFeedbackSection: some View {
        if let scheduled = matchedScheduled, let targetRange = scheduled.targetPaceRange {
            let actual = workout.averagePaceSecondsPerKm
            let status = paceStatus(actual: actual, target: targetRange)

            VStack(alignment: .leading, spacing: 10) {
                Text("PERFORMANCE")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target pace")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(
                            "\(targetRange.lowerBound.paceString(unit: appSettings.unitPreference))" +
                            " – " +
                            "\(targetRange.upperBound.paceString(unit: appSettings.unitPreference))"
                        )
                        .font(.bodyStrong)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Your pace")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(actual.paceString(unit: appSettings.unitPreference))
                            .font(.bodyStrong)
                    }
                }

                Label(status.label, systemImage: status.icon)
                    .font(.bodyStrong)
                    .foregroundStyle(status.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private struct PaceStatus {
        let label: String
        let icon: String
        let color: Color
    }

    private func paceStatus(actual: Double, target: ClosedRange<Double>) -> PaceStatus {
        if target.contains(actual) {
            return PaceStatus(label: "On target", icon: "checkmark.circle.fill", color: .success)
        }
        let margin = (target.upperBound - target.lowerBound) * 0.1 + target.upperBound * 0.05
        if actual <= target.upperBound + margin && actual >= target.lowerBound - margin {
            return PaceStatus(label: "Slightly off target", icon: "exclamationmark.circle.fill", color: .warning)
        }
        if actual < target.lowerBound {
            return PaceStatus(label: "Too fast", icon: "bolt.fill", color: .warning)
        }
        return PaceStatus(label: "Too slow", icon: "tortoise.fill", color: .destructive)
    }
}
