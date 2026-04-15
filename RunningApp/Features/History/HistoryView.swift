import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: [SortDescriptor(\RunWorkout.date, order: .reverse)])
    private var allWorkouts: [RunWorkout]

    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container

    @State private var isSyncing = false
    @State private var displayLimit = 20

    private let pageSize = 20

    private var displayedWorkouts: [RunWorkout] {
        Array(allWorkouts.prefix(displayLimit))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(displayedWorkouts.enumerated()), id: \.element.id) { index, workout in
                    NavigationLink {
                        RunSummaryView(workout: workout)
                    } label: {
                        WorkoutRowView(workout: workout)
                    }
                    .onAppear {
                        if index >= displayedWorkouts.count - 5 {
                            displayLimit = min(displayLimit + pageSize, allWorkouts.count)
                        }
                    }
                }
                .onDelete(perform: deleteWorkouts)

                if displayedWorkouts.count < allWorkouts.count {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("History")
            .toolbar {
                if isSyncing {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
            .overlay {
                if allWorkouts.isEmpty && !isSyncing {
                    ContentUnavailableView(
                        "No runs yet",
                        systemImage: "figure.run.circle",
                        description: Text("Start your first run or sync from Apple Health.")
                    )
                }
            }
            .task {
                await syncRecentHealthKitWorkouts()
            }
        }
    }

    // MARK: Delete

    private func deleteWorkouts(at offsets: IndexSet) {
        for index in offsets {
            let workout = displayedWorkouts[index]
            // Nullify the inverse relationship so CloudKit doesn't reject the delete.
            workout.scheduledWorkout?.completedWorkout = nil
            context.delete(workout)
        }
        try? context.save()
    }

    // MARK: Auto-sync

    /// Silently imports running workouts from the last 60 days that aren't
    /// already in the app. Triggered every time the History tab appears.
    @MainActor
    private func syncRecentHealthKitWorkouts() async {
        let repo = container.healthKitRepository
        guard repo.isAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await repo.requestAuthorization()
            let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()
            let existingIDs = Set(allWorkouts.compactMap(\.healthKitWorkoutID))
            let newWorkouts = try await repo.fetchImportableWorkouts(
                from: cutoff,
                to: Date(),
                existingIDs: existingIDs
            )
            for workout in newWorkouts {
                context.insert(workout)
            }
            if !newWorkouts.isEmpty {
                try context.save()
            }
        } catch {
            // Silent failure — background sync shouldn't interrupt the user
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
