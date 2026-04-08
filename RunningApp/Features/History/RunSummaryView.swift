import SwiftUI
import MapKit

struct RunSummaryView: View {
    let workout: RunWorkout

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                routeMap
                statsGrid
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
            statCell(value: workout.distanceMeters.distanceKmString, label: "Distance")
            statCell(value: workout.durationSeconds.durationString, label: "Duration")
            statCell(value: workout.averagePaceSecondsPerKm.paceString, label: "Avg Pace")
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
                            Text("km \(split.kilometer)").font(.bodyRegular)
                            Spacer()
                            Text(split.paceSecondsPerKm.paceString)
                                .font(.bodyStrong)
                        }
                        Divider()
                    }
                }
            }
        }
    }
}
