import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \RunWorkout.date, order: .reverse)
    private var workouts: [RunWorkout]

    var body: some View {
        NavigationStack {
            List {
                ForEach(workouts) { workout in
                    NavigationLink {
                        RunSummaryView(workout: workout)
                    } label: {
                        WorkoutRowView(workout: workout)
                    }
                }
            }
            .navigationTitle("History")
            .overlay {
                if workouts.isEmpty {
                    ContentUnavailableView(
                        "No runs yet",
                        systemImage: "figure.run.circle",
                        description: Text("Start your first run from the Home tab.")
                    )
                }
            }
        }
    }
}

// MARK: - WorkoutRowView

struct WorkoutRowView: View {
    let workout: RunWorkout
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.workoutType == .longRun ? "figure.run.circle.fill" : "figure.run")
                .font(.title2)
                .foregroundStyle(.brand)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(workout.workoutType.displayName)
                    .font(.bodyStrong)
                Text(workout.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(workout.distanceMeters.distanceString(unit: appSettings.unitPreference))
                    .font(.bodyStrong)
                Text(workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
