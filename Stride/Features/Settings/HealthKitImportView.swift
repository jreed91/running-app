import SwiftUI
import SwiftData

/// Lets the user retroactively import older workouts from Apple Health — runs, and
/// walks when walk import is on — that predate the app's automatic 60-day sync window.
struct HealthKitImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings
    @Query private var existingWorkouts: [RunWorkout]

    @State private var startDate: Date = Calendar.current.date(
        byAdding: .year, value: -5, to: Date()
    ) ?? Date()

    @State private var importState: ImportState = .idle

    enum ImportState: Equatable {
        case idle
        case importing
        case done(imported: Int, skipped: Int)
        case failed(String)
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
            .disabled(importState == .importing)

            LabeledContent("To") {
                Text(Date(), style: .date).foregroundStyle(.secondary)
            }
        } header: {
            Text("Date Range")
        } footer: {
            // Two `Text` literals rather than one with a ternary inside it: a ternary of
            // two string literals infers `String`, not `LocalizedStringKey`, so neither
            // arm would be extracted for translation.
            if appSettings.walkImportEnabled {
                Text("Runs and walks not already in this app will be imported.")
            } else {
                Text("Only running activities not already in this app will be imported.")
            }
        }
        .strideListRow()
    }

    private var actionSection: some View {
        Section {
            switch importState {
            case .idle:
                Button("Import Workouts") {
                    Task { await runImport() }
                }

            case .importing:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Reading Apple Health…").foregroundStyle(.secondary)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Import Again") { importState = .idle }
                    .foregroundStyle(.secondary)

            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Import failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.destructive)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Try Again") { importState = .idle }
            }
        }
        .strideListRow()
    }

    // MARK: Import logic

    @MainActor
    private func runImport() async {
        importState = .importing
        do {
            let repo = container.healthKitRepository
            try await repo.requestAuthorization()

            let allHKWorkouts = try await repo.fetchWorkouts(from: startDate, to: Date())
            // Union deletion tombstones so a manually removed run isn't re-imported here.
            let tombstonedIDs = Set(
                ((try? context.fetch(FetchDescriptor<DeletedWorkout>())) ?? []).map(\.healthKitWorkoutID)
            )
            let existingIDs = Set(existingWorkouts.compactMap(\.healthKitWorkoutID)).union(tombstonedIDs)
            let skipped = allHKWorkouts.filter { existingIDs.contains($0.uuid.uuidString) }.count

            let importContext = WorkoutImportContext.resolve(from: context)
            let newWorkouts = try await repo.fetchImportableWorkouts(
                from: startDate,
                to: Date(),
                existingIDs: existingIDs,
                context: importContext
            )
            // The same walks the background sync brings in, over the range the runner
            // chose here — a retroactive import that quietly covered only half of what
            // Stride imports would be the more surprising behaviour (N38).
            let newWalks = appSettings.walkImportEnabled
                ? try await repo.fetchImportableWalkingWorkouts(
                    from: startDate,
                    to: Date(),
                    existingIDs: existingIDs,
                    context: importContext
                )
                : []

            for workout in newWorkouts + newWalks {
                context.insert(workout)
            }
            // Only runs on or after the default pair's start date get it, so reaching
            // back a year does not put this year's shoes on last year's runs.
            ShoeAssignment.assignDefaultShoe(to: newWorkouts, in: context)
            if !newWorkouts.isEmpty || !newWalks.isEmpty {
                try context.save()
                // Weather is attached to runs only, matching the background sync: it feeds
                // the coach's per-run analysis, which never reads a walk.
                for workout in newWorkouts {
                    if let coordinate = workout.routeCoordinates.first {
                        await container.attachWeather(to: workout, coordinate: coordinate)
                    }
                }
            }

            importState = .done(imported: newWorkouts.count + newWalks.count, skipped: skipped)
        } catch {
            importState = .failed(error.localizedDescription)
        }
    }
}
