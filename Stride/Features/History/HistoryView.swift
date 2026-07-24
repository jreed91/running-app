import SwiftUI
import SwiftData

// MARK: - History Entry (merges run + strength)

private enum HistoryEntry: Identifiable {
    case run(RunWorkout)
    case strength(StrengthWorkout)

    var id: String {
        switch self {
        case .run(let w):      return "run-\(w.id)"
        case .strength(let w): return "str-\(w.id)"
        }
    }

    var date: Date {
        switch self {
        case .run(let w):      return w.date
        case .strength(let w): return w.date
        }
    }
}

// MARK: - HistoryView

struct HistoryView: View {
    @Query(sort: [SortDescriptor(\RunWorkout.date, order: .reverse)])
    private var allRunWorkouts: [RunWorkout]

    @Query(sort: [SortDescriptor(\StrengthWorkout.date, order: .reverse)])
    private var allStrengthWorkouts: [StrengthWorkout]

    @Environment(\.appContainer) private var container

    @State private var isSyncing = false
    @State private var displayLimit = 20

    private let pageSize = 20

    private var sortedEntries: [HistoryEntry] {
        let runs = allRunWorkouts.map { HistoryEntry.run($0) }
        let strength = allStrengthWorkouts.map { HistoryEntry.strength($0) }
        return (runs + strength).sorted { $0.date > $1.date }
    }

    private var displayedEntries: [HistoryEntry] {
        Array(sortedEntries.prefix(displayLimit))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(displayedEntries.enumerated()), id: \.element.id) { index, entry in
                    entryRow(for: entry, index: index)
                }
                .onDelete(perform: deleteEntries)

                if displayedEntries.count < sortedEntries.count {
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
                if allRunWorkouts.isEmpty && allStrengthWorkouts.isEmpty && !isSyncing {
                    ContentUnavailableView(
                        "No workouts yet",
                        systemImage: "figure.run.circle",
                        description: Text("Start a workout or sync from Apple Health.")
                    )
                }
            }
            .task {
                await syncRecentHealthKitWorkouts()
            }
        }
    }

    @ViewBuilder
    private func entryRow(for entry: HistoryEntry, index: Int) -> some View {
        switch entry {
        case .run(let workout):
            NavigationLink { RunSummaryView(workout: workout) } label: {
                WorkoutRowView(workout: workout)
            }
            .onAppear { loadMoreIfNeeded(index: index) }
        case .strength(let workout):
            NavigationLink { StrengthSummaryView(workout: workout) } label: {
                StrengthWorkoutRowView(workout: workout)
            }
            .onAppear { loadMoreIfNeeded(index: index) }
        }
    }

    private func loadMoreIfNeeded(index: Int) {
        if index >= displayedEntries.count - 5 {
            displayLimit = min(displayLimit + pageSize, sortedEntries.count)
        }
    }

    // MARK: Delete

    private func deleteEntries(at offsets: IndexSet) {
        // Snapshot the entries before deleting: `displayedEntries` is recomputed on every
        // access, so mutating the store mid-loop would shift the offsets we're iterating.
        // All invariant repair (tombstones, scheduled-day reset) lives in the repository.
        let entries = displayedEntries
        for index in offsets where entries.indices.contains(index) {
            switch entries[index] {
            case .run(let workout):
                try? container.workoutRepository.delete(workout)
            case .strength(let workout):
                try? container.workoutRepository.delete(workout)
            }
        }
    }

    // MARK: Auto-sync

    /// Refreshes from HealthKit when the tab opens, through the **canonical** importer.
    ///
    /// This screen used to run its own import, which diverged from `WorkoutSyncService`
    /// in ways the user felt: imported runs were never linked to their scheduled day
    /// (so the plan kept showing a workout as missed after it had been run), strength
    /// sessions were deduplicated by calendar day (collapsing a morning app-log and an
    /// evening Watch session), and no review banner was raised. Since History usually
    /// imports first, its rules were the ones that won (N4).
    @MainActor
    private func syncRecentHealthKitWorkouts() async {
        guard !UITestingSupport.isEnabled else { return }
        let repo = container.healthKitRepository
        guard repo.isAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await repo.requestAuthorization()
        } catch {
            AppLogger.log(
                "History sync skipped — HealthKit authorization failed: \(error.localizedDescription)",
                label: "HealthKit",
                level: .warning
            )
            return
        }
        // A wider window than a routine sync: opening History is an explicit "show me
        // everything" gesture, and it is the screen where a missing run is noticed.
        await container.workoutSyncService.syncNow(lookbackDays: 60, source: "history")
    }
}

// MARK: - WorkoutRowView

struct WorkoutRowView: View {
    let workout: RunWorkout
    @Environment(AppSettings.self) private var appSettings

    private var displayType: WorkoutType {
        workout.scheduledWorkout?.workoutType ?? workout.workoutType
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(displayType.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                StrideIcon(name: displayType.strideIcon, size: 22,
                           color: displayType.color, strokeWeight: 2.0)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayType.displayName)
                    .font(.bodyStrong)
                HStack(spacing: 4) {
                    Text(workout.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if workout.scheduledWorkout != nil {
                        Image(systemName: "link")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.brand)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(workout.distanceMeters.distanceString(unit: appSettings.unitPreference))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text(workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference)
                    .replacingOccurrences(of: " min/km", with: "")
                    .replacingOccurrences(of: " min/mi", with: ""))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let w = workout.weather {
                    HStack(spacing: 3) {
                        Image(systemName: w.conditionSymbol)
                            .symbolRenderingMode(.multicolor)
                        Text(w.temperatureString(unit: appSettings.unitPreference))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - StrengthWorkoutRowView

struct StrengthWorkoutRowView: View {
    let workout: StrengthWorkout

    private var title: String {
        workout.scheduledWorkout?.strengthPlan?.focus.displayName ?? "Strength Workout"
    }

    private var durationLabel: String {
        let minutes = Int(workout.durationSeconds) / 60
        return "\(minutes) min"
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(WorkoutType.strength.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                StrideIcon(name: WorkoutType.strength.strideIcon, size: 22,
                           color: WorkoutType.strength.color, strokeWeight: 2.0)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.bodyStrong)
                HStack(spacing: 4) {
                    Text(workout.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if workout.scheduledWorkout != nil {
                        Image(systemName: "link")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.brand)
                    }
                    if workout.healthKitWorkoutID != nil {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(durationLabel)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                let setCount = workout.completedSets.count
                if setCount > 0 {
                    Text("\(setCount) sets")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
