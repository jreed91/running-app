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

    @Environment(\.modelContext) private var context
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
                        label: {
                            Label("No workouts yet", strideIcon: .run)
                        },
                        description: {
                            Text("Start a workout or sync from Apple Health.")
                        }
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
        for index in offsets {
            switch displayedEntries[index] {
            case .run(let workout):
                workout.scheduledWorkout?.completedWorkout = nil
                workout.scheduledWorkout?.linkedRunWorkoutID = nil
                workout.linkedScheduledWorkoutID = nil
                if let hkID = workout.healthKitWorkoutID {
                    context.insert(DeletedWorkout(healthKitWorkoutID: hkID))
                }
                context.delete(workout)
            case .strength(let workout):
                workout.scheduledWorkout?.completedStrengthWorkout = nil
                workout.scheduledWorkout?.linkedStrengthWorkoutID = nil
                workout.linkedScheduledWorkoutID = nil
                context.delete(workout)
            }
        }
        try? context.save()
    }

    // MARK: Auto-sync

    @MainActor
    private func syncRecentHealthKitWorkouts() async {
        guard !UITestingSupport.isEnabled else { return }
        let repo = container.healthKitRepository
        guard repo.isAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await repo.requestAuthorization()
            let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()

            let existingRunIDs = Set(allRunWorkouts.compactMap(\.healthKitWorkoutID))
            let newRunWorkouts = try await repo.fetchImportableWorkouts(
                from: cutoff, to: Date(), existingIDs: existingRunIDs
            )
            for workout in newRunWorkouts { context.insert(workout) }
            if !newRunWorkouts.isEmpty {
                try context.save()
                for workout in newRunWorkouts {
                    if let coordinate = workout.routeCoordinates.first {
                        await container.attachWeather(to: workout, coordinate: coordinate)
                    }
                }
            }

            let existingStrengthIDs = Set(allStrengthWorkouts.compactMap(\.healthKitWorkoutID))
            let hkStrengthWorkouts = try await repo.fetchImportableStrengthWorkouts(
                from: cutoff, to: Date(), existingIDs: existingStrengthIDs
            )
            var unlinked = allStrengthWorkouts.filter { $0.healthKitWorkoutID == nil }
            var toInsert: [StrengthWorkout] = []
            for hkWorkout in hkStrengthWorkouts {
                let hkDay = Calendar.current.startOfDay(for: hkWorkout.date)
                if let idx = unlinked.firstIndex(where: {
                    Calendar.current.startOfDay(for: $0.date) == hkDay
                }) {
                    unlinked[idx].healthKitWorkoutID = hkWorkout.healthKitWorkoutID
                    unlinked.remove(at: idx)
                } else {
                    toInsert.append(hkWorkout)
                }
            }
            for workout in toInsert { context.insert(workout) }
            if !hkStrengthWorkouts.isEmpty { try context.save() }
        } catch {
            // Silent failure — background sync shouldn't interrupt the user
        }
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
                        StrideIcon(name: .link, size: 9, color: .brand)
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
                        StrideIcon(name: StrideIconName(weatherSymbol: w.conditionSymbol), size: 11, color: .secondary)
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
                        StrideIcon(name: .link, size: 9, color: .brand)
                    }
                    if workout.healthKitWorkoutID != nil {
                        StrideIcon(name: .heart, size: 9, color: .red)
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
