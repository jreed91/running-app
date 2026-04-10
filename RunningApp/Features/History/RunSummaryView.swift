import SwiftUI
import MapKit
import SwiftData

struct RunSummaryView: View {
    let workout: RunWorkout

    @Environment(AppSettings.self) private var appSettings
    @Query private var scheduledWorkouts: [ScheduledWorkout]

    private var matchedScheduled: ScheduledWorkout? {
        scheduledWorkouts.first { $0.completedWorkout?.id == workout.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                routeMap
                statsGrid
                performanceFeedbackSection
                splitsSection
            }
            .padding()
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
                    .overlay { Label("No route data", systemImage: "map.slash") }
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
            if let gain = workout.elevationGainMeters {
                statCell(value: String(format: "+%.0f m", gain), label: "Elevation")
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
        // Within 10% of the range bounds
        let margin = (target.upperBound - target.lowerBound) * 0.1 + target.upperBound * 0.05
        if actual <= target.upperBound + margin && actual >= target.lowerBound - margin {
            return PaceStatus(label: "Slightly off target", icon: "exclamationmark.circle.fill", color: .warning)
        }
        if actual < target.lowerBound {
            return PaceStatus(label: "Too fast", icon: "bolt.fill", color: .warning)
        }
        return PaceStatus(label: "Too slow", icon: "tortoise.fill", color: .destructive)
    }

    // MARK: Splits

    private var splitsSection: some View {
        Group {
            if !workout.splits.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SPLITS")
                        .font(.sectionHeader)
                        .foregroundStyle(.secondary)
                    ForEach(workout.splits, id: \.kilometer) { split in
                        HStack {
                            Text("\(appSettings.unitPreference.distanceLabel) \(split.kilometer)").font(.bodyRegular)
                            Spacer()
                            Text(split.paceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                                .font(.bodyStrong)
                        }
                        Divider()
                    }
                }
            }
        }
    }
}
