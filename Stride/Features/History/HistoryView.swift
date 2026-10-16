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
    /// Search term. Like `displayLimit`, it is applied by re-initialising the list, since
    /// the run-side filter is a fetch predicate rather than an in-memory pass (U8).
    @State private var searchText = ""
    /// Date range and minimum distance, applied the same way and for the same reason.
    @State private var filter = HistoryFilter()

    var body: some View {
        NavigationStack {
            HistoryEntryList(
                limit: displayLimit,
                searchText: searchText,
                filter: filter,
                isSyncing: isSyncing,
                clearFilter: { filter = HistoryFilter() },
                syncNow: { await syncRecentHealthKitWorkouts() }
            ) {
                displayLimit += HistoryEntryList.pageSize
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Search workouts")
            // `.task` fires once for the view's lifetime, and a `TabView` keeps its
            // children alive — so a runner who opened History, recorded a Watch run,
            // and came back had no way to make the new run appear (U8). Pull-to-refresh
            // is the expected gesture and runs the same canonical importer.
            .refreshable {
                await syncRecentHealthKitWorkouts()
            }
            // Both narrow the list, so both send paging back to the first page —
            // otherwise a filter applied at page five keeps fetching five pages of a
            // much smaller result set.
            .onChange(of: searchText) { _, _ in
                displayLimit = HistoryEntryList.pageSize
            }
            .onChange(of: filter) { _, _ in
                displayLimit = HistoryEntryList.pageSize
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HistoryFilterMenu(filter: $filter)
                }
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
    private let searchTerm: String
    private let filter: HistoryFilter
    private let isSyncing: Bool
    private let clearFilter: () -> Void
    /// Runs the same importer as pull-to-refresh, so the empty state can offer the action it
    /// names instead of only describing it (S6).
    private let syncNow: () async -> Void
    private let loadMore: () -> Void

    @Environment(AppContainer.self) private var container

    @Query private var runs: [RunWorkout]
    @Query private var strengthWorkouts: [StrengthWorkout]

    /// Rows the runner has asked to delete, held until the confirmation is answered.
    @State private var pendingDeletion: IndexSet? = nil
    @State private var deleteErrorMessage: String? = nil

    init(
        limit: Int,
        searchText: String,
        filter: HistoryFilter,
        isSyncing: Bool,
        clearFilter: @escaping () -> Void,
        syncNow: @escaping () async -> Void,
        loadMore: @escaping () -> Void
    ) {
        self.limit = limit
        self.filter = filter
        self.isSyncing = isSyncing
        self.clearFilter = clearFilter
        self.syncNow = syncNow
        self.loadMore = loadMore

        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.searchTerm = term

        // Types are resolved from their *localized* names here, in Swift, and the
        // predicate compares raw values — so search matches what the runner actually
        // reads on the row without the stored enum ever moving with the device language.
        let matchingTypeRaws = term.isEmpty ? [] : WorkoutType.allCases
            .filter { $0.localizedName.localizedStandardContains(term) }
            .map(\.rawValue)

        // The filter's two axes go into the predicate as neutral values — `distantPast`
        // and `0` are true of every row — so an inactive filter needs no separate
        // predicate. Search still does: with no term, `matchingTypeRaws` is empty and the
        // search clause would be false for every run rather than absent.
        let earliestDate = filter.dateRange.earliestDate() ?? .distantPast
        let minimumMeters = filter.minimumDistance.meters ?? 0

        var runDescriptor = FetchDescriptor<RunWorkout>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        if term.isEmpty {
            runDescriptor.predicate = #Predicate<RunWorkout> { run in
                run.date >= earliestDate && run.distanceMeters >= minimumMeters
            }
        } else {
            runDescriptor.predicate = #Predicate<RunWorkout> { run in
                (matchingTypeRaws.contains(run.workoutTypeRaw)
                    || (run.notes?.localizedStandardContains(term) ?? false))
                    && run.date >= earliestDate
                    && run.distanceMeters >= minimumMeters
            }
        }
        runDescriptor.fetchLimit = limit + 1
        _runs = Query(runDescriptor)

        // The strength side takes the date bound in its predicate and everything else in
        // memory: its title comes from the plan's focus across two relationships, which a
        // fetch predicate can't reach, and a distance floor excludes it outright
        // (`HistoryFilter.includesStrengthWorkouts`). The fetch stays bounded either way.
        var strengthDescriptor = FetchDescriptor<StrengthWorkout>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        strengthDescriptor.predicate = #Predicate<StrengthWorkout> { workout in
            workout.date >= earliestDate
        }
        strengthDescriptor.fetchLimit = limit + 1
        _strengthWorkouts = Query(strengthDescriptor)
    }

    /// Newest-first merge of both fetches. Either type can supply the whole page, which is
    /// why each is fetched to the full limit rather than to some share of it.
    private var entries: [HistoryEntry] {
        let matchingStrength = filter.includesStrengthWorkouts
            ? strengthWorkouts.filter(matchesSearch)
            : []
        let merged = runs.map { HistoryEntry.run($0) } + matchingStrength.map { HistoryEntry.strength($0) }
        return merged.sorted { $0.date > $1.date }
    }

    private func matchesSearch(_ workout: StrengthWorkout) -> Bool {
        guard !searchTerm.isEmpty else { return true }
        if WorkoutType.strength.localizedName.localizedStandardContains(searchTerm) { return true }
        if let focus = workout.scheduledWorkout?.strengthPlan?.focus,
           focus.localizedName.localizedStandardContains(searchTerm) {
            return true
        }
        return false
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
            // Swiping used to delete immediately while the same delete from a run's
            // summary asked first — and the swipe is the *less* recoverable path, since
            // it also writes a tombstone that keeps the run from returning on the next
            // Health sync (U6).
            .onDelete { offsets in pendingDeletion = offsets }
            .strideListRow()

            if hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .strideList()
        .overlay { emptyStateOverlay }
        .confirmationDialog(
            "Delete this workout?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let offsets = pendingDeletion { deleteEntries(at: offsets) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This can't be undone, and the workout won't come back on the next Apple Health sync.")
        }
        // The delete used to be a `try?`, so a failure left the row on screen with no
        // explanation of why it hadn't gone (U6).
        .alert(
            "Couldn't delete that workout",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    /// Empty, searching, and first-sync states. The list used to render a blank screen
    /// during the initial Health import, with only a 0.8×-scaled toolbar spinner to say
    /// anything was happening (U8).
    @ViewBuilder
    private var emptyStateOverlay: some View {
        if !entries.isEmpty {
            EmptyView()
        } else if isSyncing {
            VStack(spacing: 12) {
                ProgressView()
                Text("Checking Apple Health for recent workouts…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, AppSpacing.huge)
        } else if !searchTerm.isEmpty {
            StrideEmptyState(
                "No results for “\(searchTerm)”",
                systemImage: "magnifyingglass",
                description: Text("Check the spelling or try a new search.")
            )
        } else if filter.isActive {
            // A filter that hides everything has to say so *and* offer the way out —
            // otherwise the screen is indistinguishable from "no workouts yet", and the
            // control that caused it is a glyph in the toolbar.
            StrideEmptyState(
                "No matching workouts",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("\(filter.dateRange.localizedName) · \(filter.minimumDistance.localizedName)")
            ) {
                Button("Clear Filters") { clearFilter() }
            }
        } else {
            // The description named two actions and offered neither, leaving the only route
            // to either one an unlabelled toolbar glyph or a gesture on an empty list (S6).
            // The filter variant above already uses the `actions:` slot; so does this.
            StrideEmptyState(
                "No workouts yet",
                systemImage: "figure.run.circle",
                description: Text("Start a run, or bring in what you've already recorded.")
            ) {
                Button("Start a Run") {
                    container.appNavigation.select(.home)
                    container.activeRunPresentation.startOrReopen(
                        scheduledWorkout: nil,
                        isRunInProgress: container.workoutTrackerService.isRecording
                    )
                }

                if container.healthKitRepository.isAvailable {
                    Button("Sync Apple Health") {
                        Task { await syncNow() }
                    }
                    .buttonStyle(.strideButton(.secondary, fullWidth: false))
                }
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
        var failure: Error?
        for index in offsets where entries.indices.contains(index) {
            do {
                switch entries[index] {
                case .run(let workout):
                    try container.workoutRepository.delete(workout)
                case .strength(let workout):
                    try container.workoutRepository.delete(workout)
                }
            } catch {
                failure = error
                AppLogger.log(
                    "Failed to delete a history entry: \(error.localizedDescription)",
                    label: "History",
                    level: .error
                )
            }
        }
        if let failure {
            deleteErrorMessage = failure.localizedDescription
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
            displayType.localizedName,
            workout.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        ]
        if workout.isCrossTraining {
            if workout.distanceMeters > 0 {
                parts.append(workout.distanceMeters.distanceString(unit: appSettings.unitPreference))
            }
            parts.append(workout.durationSeconds.durationString)
        } else {
            parts.append(workout.distanceMeters.distanceString(unit: appSettings.unitPreference))
            parts.append(workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
        }
        if workout.scheduledWorkout != nil { parts.append("linked to a planned workout") }
        if let weather = workout.weather {
            parts.append(weather.temperatureString(unit: appSettings.unitPreference))
        }
        return parts.joined(separator: ", ")
    }

    /// Distance, or the time for a cross-training session that recorded none (B8).
    private var primaryMetric: String {
        workout.isCrossTraining && workout.distanceMeters <= 0
            ? workout.durationSeconds.durationString
            : workout.distanceMeters.distanceString(unit: appSettings.unitPreference)
    }

    /// Pace for a run or walk; for a cross-training session its time, since a ride's
    /// minutes per kilometre is not a pace anyone reads (B8).
    private var secondaryMetric: String? {
        guard workout.isCrossTraining else {
            // `paceValueString` is the unit-less form of exactly this number. The row
            // used to build it by string-stripping " min/km" off `paceString`, which
            // silently stops matching the moment the app is localized (U8).
            return workout.averagePaceSecondsPerKm.paceValueString(unit: appSettings.unitPreference)
        }
        return workout.distanceMeters > 0 ? workout.durationSeconds.durationString : nil
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
                Text(displayType.localizedName)
                    .font(.bodyStrong)
                HStack(spacing: 4) {
                    Text(workout.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if workout.scheduledWorkout != nil {
                        Image(systemName: "link")
                            .font(.dsCaption2.weight(.semibold))
                            .foregroundStyle(.brand)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(primaryMetric)
                    .font(.dsSubhead.weight(.semibold).monospaced())
                if let secondaryMetric {
                    Text(secondaryMetric)
                        .font(.dsCaption.weight(.medium).monospaced())
                        .foregroundStyle(.secondary)
                }
                if let w = workout.weather {
                    HStack(spacing: 3) {
                        Image(systemName: w.conditionSymbol)
                            .symbolRenderingMode(.multicolor)
                        Text(w.temperatureString(unit: appSettings.unitPreference))
                    }
                    .font(.dsCaption2.weight(.medium))
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
        workout.scheduledWorkout?.strengthPlan?.focus.localizedName ?? "Strength Workout"
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
                            .font(.dsCaption2.weight(.semibold))
                            .foregroundStyle(.brand)
                    }
                    if workout.healthKitWorkoutID != nil {
                        Image(systemName: "heart.fill")
                            .font(.dsCaption2)
                            .foregroundStyle(.destructive)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(durationLabel)
                    .font(.dsSubhead.weight(.semibold).monospaced())
                let setCount = workout.completedSets.count
                if setCount > 0 {
                    Text("\(setCount) sets")
                        .font(.dsCaption.weight(.medium).monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowDescription)
    }
}
