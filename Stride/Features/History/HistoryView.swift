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
    @Environment(AppContainer.self) private var container

    @State private var isSyncing = false
    /// How many entries the list is currently showing. Held here, and passed *into* the
    /// list, because a `@Query`'s fetch limit is fixed when the view is initialised — so
    /// paging means re-initialising a child view with a bigger limit (D6). The list itself
    /// used to fetch both whole tables to show twenty rows.
    @State private var displayLimit = HistoryEntryList.pageSize

    var body: some View {
        NavigationStack {
            HistoryEntryList(limit: displayLimit, isSyncing: isSyncing) {
                displayLimit += HistoryEntryList.pageSize
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
            .task {
                await syncRecentHealthKitWorkouts()
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

// MARK: - HistoryEntryList

/// The merged run + strength list, fetching only as far as it displays.
///
/// Both queries are built in `init` from the caller's `limit`, which is what makes paging
/// possible at all: `@Query` resolves its descriptor once per view initialisation, so a
/// growing page size has to arrive as a new value from the parent (D6).
///
/// Each side fetches one row *beyond* the page. That extra row is never displayed — it is
/// how the list knows more history exists without counting the whole table, which is the
/// question the old full-table fetch was really answering.
private struct HistoryEntryList: View {
    static let pageSize = 20

    private let limit: Int
    private let isSyncing: Bool
    private let loadMore: () -> Void

    @Environment(AppContainer.self) private var container

    @Query private var runs: [RunWorkout]
    @Query private var strengthWorkouts: [StrengthWorkout]

    init(limit: Int, isSyncing: Bool, loadMore: @escaping () -> Void) {
        self.limit = limit
        self.isSyncing = isSyncing
        self.loadMore = loadMore

        var runDescriptor = FetchDescriptor<RunWorkout>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        runDescriptor.fetchLimit = limit + 1
        _runs = Query(runDescriptor)

        var strengthDescriptor = FetchDescriptor<StrengthWorkout>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        strengthDescriptor.fetchLimit = limit + 1
        _strengthWorkouts = Query(strengthDescriptor)
    }

    /// Newest-first merge of both fetches. Either type can supply the whole page, which is
    /// why each is fetched to the full limit rather than to some share of it.
    private var entries: [HistoryEntry] {
        let merged = runs.map { HistoryEntry.run($0) } + strengthWorkouts.map { HistoryEntry.strength($0) }
        return merged.sorted { $0.date > $1.date }
    }

    private var displayedEntries: [HistoryEntry] {
        Array(entries.prefix(limit))
    }

    /// True when at least one entry exists beyond the page — the extra row each fetch asked
    /// for. Never a claim about *how many* remain, which nothing on this screen needs.
    private var hasMore: Bool {
        entries.count > limit
    }

    var body: some View {
        List {
            ForEach(Array(displayedEntries.enumerated()), id: \.element.id) { index, entry in
                entryRow(for: entry, index: index)
            }
            .onDelete(perform: deleteEntries)

            if hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .overlay {
            if entries.isEmpty && !isSyncing {
                ContentUnavailableView(
                    "No workouts yet",
                    systemImage: "figure.run.circle",
                    description: Text("Start a workout or sync from Apple Health.")
                )
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
        guard hasMore, index >= displayedEntries.count - 5 else { return }
        loadMore()
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
}

// MARK: - WorkoutRowView

struct WorkoutRowView: View {
    let workout: RunWorkout
    @Environment(AppSettings.self) private var appSettings

    private var displayType: WorkoutType {
        workout.scheduledWorkout?.workoutType ?? workout.workoutType
    }

    /// One spoken sentence per row, rather than the six loose fragments the stacks produce
    /// ("Tempo", "Tue, Mar 3", "5.2 km", "4:32", "12°C") plus a "link" glyph read as the
    /// word "link" (N18). The pace is restated with its unit, which the visible label
    /// strips for space, and the icons are said in words.
    private var rowDescription: String {
        var parts = [
            displayType.displayName,
            workout.date.formatted(.dateTime.weekday(.wide).month(.wide).day()),
            workout.distanceMeters.distanceString(unit: appSettings.unitPreference),
            workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference)
        ]
        if workout.scheduledWorkout != nil { parts.append("linked to a planned workout") }
        if let weather = workout.weather {
            parts.append(weather.temperatureString(unit: appSettings.unitPreference))
        }
        return parts.joined(separator: ", ")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowDescription)
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

    /// The row as one spoken sentence, with the link and Apple Health glyphs said in
    /// words instead of read as "link" and "heart fill" (N18).
    private var rowDescription: String {
        var parts = [
            title,
            workout.date.formatted(.dateTime.weekday(.wide).month(.wide).day()),
            "\(Int(workout.durationSeconds) / 60) minutes"
        ]
        let setCount = workout.completedSets.count
        if setCount > 0 { parts.append("\(setCount) sets") }
        if workout.scheduledWorkout != nil { parts.append("linked to a planned workout") }
        if workout.healthKitWorkoutID != nil { parts.append("from Apple Health") }
        return parts.joined(separator: ", ")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowDescription)
    }
}
