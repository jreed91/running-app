import SwiftUI
import SwiftData

/// Lets the user retroactively import older workouts from Apple Health — runs, strength
/// workouts, and walks when walk import is on — that predate the app's automatic sync window.
struct HealthKitImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings

    @State private var startDate: Date = Calendar.current.date(
        byAdding: .year, value: -5, to: Date()
    ) ?? Date()

    @State private var importState: ImportState = .idle

    enum ImportState: Equatable {
        case idle
        /// How many workouts are in so far, and how far back the import has read.
        case importing(imported: Int, reachedBack: Date?)
        case done(imported: Int, skipped: Int)
        case failed(String)
    }

    private var isImporting: Bool {
        if case .importing = importState { return true }
        return false
    }

    var body: some View {
        Form {
            dateRangeSection
            actionSection
        }
        .strideList()
        .navigationTitle("Import from Apple Health")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sections

    private var dateRangeSection: some View {
        Section {
            DatePicker(
                "From",
                selection: $startDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .disabled(isImporting)

            LabeledContent("To") {
                Text(Date(), style: .date).foregroundStyle(.secondary)
            }
        } header: {
            Text("Date range")
        } footer: {
            // Two `Text` literals rather than one with a ternary inside it: a ternary of
            // two string literals infers `String`, not `LocalizedStringKey`, so neither
            // arm would be extracted for translation.
            if appSettings.walkImportEnabled {
                Text("Runs, walks and strength workouts not already in this app will be imported.")
            } else {
                Text("Runs and strength workouts not already in this app will be imported.")
            }
        }
        .strideListRow()
    }

    private var actionSection: some View {
        Section {
            switch importState {
            case .idle:
                Button("Import workouts") {
                    Task { await runImport() }
                }

            case .importing(let imported, let reachedBack):
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reading Apple Health…").foregroundStyle(.secondary)
                        if let reachedBack {
                            Text("\(imported) imported, back to \(reachedBack.formatted(.dateTime.month(.abbreviated).year()))")
                                .font(.dsCaption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

            case .done(let imported, let skipped):
                VStack(alignment: .leading, spacing: 6) {
                    if imported == 0 {
                        Label("Already up to date", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "\(imported) workout\(imported == 1 ? "" : "s") imported",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(Color.success)
                    }

                    if skipped > 0 {
                        Text("\(skipped) already in app, skipped")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Import again") { importState = .idle }
                    .buttonStyle(.strideButton(.secondary))

            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Import failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.destructive)
                    Text(message)
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
                Button("Try again") { importState = .idle }
            }
        }
        .strideListRow()
    }

    // MARK: Import logic

    /// Reads the range a month at a time, newest first, saving each month before
    /// reading the next (see `HealthImportChunks`). Reading all of it at once ran the
    /// phone out of memory on a long history.
    @MainActor
    private func runImport() async {
        importState = .importing(imported: 0, reachedBack: nil)
        let now = Date()
        var totals = ImportTotals()
        do {
            try await container.healthKitRepository.requestAuthorization()
            for range in HealthImportChunks.ranges(from: startDate, to: now) {
                try Task.checkCancellation()
                try await importStretch(range, now: now, totals: &totals)
                importState = .importing(imported: totals.imported, reachedBack: range.start)
            }
            importState = .done(imported: totals.imported, skipped: totals.skipped)
        } catch {
            // What came in before the failure is saved; say so rather than lose it.
            importState = totals.imported > 0
                ? .done(imported: totals.imported, skipped: totals.skipped)
                : .failed(error.localizedDescription)
        }
    }

    private struct ImportTotals {
        var imported = 0
        var skipped = 0
    }

    /// One stretch of the range: read, de-duplicated, inserted and saved.
    @MainActor
    private func importStretch(_ range: DateInterval, now: Date, totals: inout ImportTotals) async throws {
        let repo = container.healthKitRepository

        let allHKWorkouts = try await repo.fetchWorkouts(from: range.start, to: range.end)
        // Union deletion tombstones so a manually removed run isn't re-imported here.
        let tombstonedIDs = Set(
            ((try? context.fetch(FetchDescriptor<DeletedWorkout>())) ?? []).map(\.healthKitWorkoutID)
        )
        // Ids only (P3), fetched again for each stretch so the one before counts.
        let existingIDs = Set(
            try context.fetch(RunWorkout.identityDescriptor).compactMap(\.healthKitWorkoutID)
        ).union(tombstonedIDs)
        totals.skipped += allHKWorkouts.filter { existingIDs.contains($0.uuid.uuidString) }.count

        let importContext = WorkoutImportContext.resolve(from: context)
        let fetchedWorkouts = try await repo.fetchImportableWorkouts(
            from: range.start,
            to: range.end,
            existingIDs: existingIDs,
            context: importContext
        )
        // Stride's own export of a run it already has links to that run rather than
        // importing a second copy, as in the background sync (P1.3).
        // Fetched again after the HealthKit reads, as the background sync does: a run
        // finished while they were awaited is exactly the one whose export this holds.
        let stored = try context.fetch(RunWorkout.identityDescriptor)
        let afterExports = WorkoutSyncService.withoutOwnExports(fetchedWorkouts, stored: stored)
        let relinked = fetchedWorkouts.count - afterExports.count
        if relinked > 0 {
            context.saveOrLog("runs relinked to their own HealthKit export")
        }
        totals.skipped += relinked
        // A Watch or another app's recording of a run Stride already has is the same
        // run, not a second one, as in the background sync.
        let newWorkouts = WorkoutSyncService.splittingSameTimeCopies(afterExports, stored: stored).kept
        // The same walks the background sync brings in, over the range the runner
        // chose here — a retroactive import that quietly covered only half of what
        // Stride imports would be the more surprising behaviour (N38).
        let newWalks = appSettings.walkImportEnabled
            ? try await repo.fetchImportableWalkingWorkouts(
                from: range.start,
                to: range.end,
                existingIDs: existingIDs,
                context: importContext
            )
            : []

        // Strength workouts from the Watch or another app, merged as the background
        // sync merges them, so a gym session logged here and recorded on the Watch
        // too stays one session.
        let strengthExistingIDs = Set(
            try context.fetch(FetchDescriptor<StrengthWorkout>()).compactMap(\.healthKitWorkoutID)
        ).union(tombstonedIDs)
        let importedStrength = try await repo.fetchImportableStrengthWorkouts(
            from: range.start,
            to: range.end,
            existingIDs: strengthExistingIDs
        )
        let strength = WorkoutSyncService.mergeStrengthImports(
            importedStrength,
            stored: try context.fetch(FetchDescriptor<StrengthWorkout>()),
            context: context
        )
        totals.skipped += strength.linked + strength.duplicates

        for workout in newWorkouts + newWalks {
            context.insert(workout)
        }
        // Only runs on or after the default pair's start date get it, so reaching
        // back a year does not put this year's shoes on last year's runs.
        ShoeAssignment.assignDefaultShoe(to: newWorkouts, in: context)
        if !newWorkouts.isEmpty || !newWalks.isEmpty || !importedStrength.isEmpty {
            try context.save()
            // Weather is attached to recent runs only, matching the background sync,
            // which never reaches further back than its own short window.
            for workout in newWorkouts where HealthImportChunks.wantsWeather(workout.date, now: now) {
                if let coordinate = workout.routeCoordinates.first {
                    await container.attachWeather(to: workout, coordinate: coordinate)
                }
            }
        }
        totals.imported += newWorkouts.count + newWalks.count + strength.inserted.count
    }
}
