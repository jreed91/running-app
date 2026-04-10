import SwiftUI

struct WorkoutDetailView: View {
    let workout: ScheduledWorkout

    @Environment(\.appContainer) private var container
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                if let range = workout.targetPaceRange {
                    paceSection(range: range)
                }
                if !workout.intervals.isEmpty {
                    intervalsSection
                }
                if let dist = workout.targetDistanceMeters {
                    distanceSection(dist: dist)
                }
                if let notes = workout.notes {
                    notesSection(notes: notes)
                }
            }
            .padding()
        }
        .navigationTitle(workout.workoutType.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sections

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(workout.workoutType.displayName)
                    .font(.metricSmall)
                Text(workout.scheduledDate, style: .date)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if workout.isCompleted {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.success)
            }
        }
    }

    private func paceSection(range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TARGET PACE").font(.sectionHeader).foregroundStyle(.secondary)
            Text("\(range.lowerBound.paceString(unit: appSettings.unitPreference)) – \(range.upperBound.paceString(unit: appSettings.unitPreference))")
                .font(.metricSmall)
        }
    }

    private var intervalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INTERVALS").font(.sectionHeader).foregroundStyle(.secondary)
            ForEach(Array(workout.intervals.enumerated()), id: \.offset) { _, interval in
                HStack {
                    Text("\(interval.repetitions) ×")
                        .font(.bodyStrong)
                    if let dist = interval.distanceMeters {
                        Text(String(format: "%.0f m", dist))
                    }
                    Spacer()
                    if let pace = interval.targetPaceSecondsPerKm {
                        Text("@ \(pace.paceString(unit: appSettings.unitPreference))")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func distanceSection(dist: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DISTANCE").font(.sectionHeader).foregroundStyle(.secondary)
            Text(dist.distanceString(unit: appSettings.unitPreference)).font(.metricSmall)
        }
    }

    private func notesSection(notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES").font(.sectionHeader).foregroundStyle(.secondary)
            Text(notes)
                .font(.bodyRegular)
                .padding()
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
