import SwiftUI
import SwiftData

/// Lets the user retroactively import older running workouts from Apple Health
/// that predate the app's automatic 60-day sync window.
struct HealthKitImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container
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
            Text("Only running activities not already in this app will be imported.")
        }
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

            let newWorkouts = try await repo.fetchImportableWorkouts(
                from: startDate,
                to: Date(),
                existingIDs: existingIDs
            )

            for workout in newWorkouts {
                context.insert(workout)
            }
            if !newWorkouts.isEmpty {
                try context.save()
                for workout in newWorkouts {
                    if let coordinate = workout.routeCoordinates.first {
                        await container.attachWeather(to: workout, coordinate: coordinate)
                    }
                }
            }

            importState = .done(imported: newWorkouts.count, skipped: skipped)
        } catch {
            importState = .failed(error.localizedDescription)
        }
    }
}
