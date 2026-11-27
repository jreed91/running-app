import SwiftData
import SwiftUI

// MARK: - MyWorkoutsView

/// The runner's own workouts, and the classics to start one from (Custom workouts, PR 2).
///
/// Reached from the "My workouts" tile in Plan tools. A row opens the workout's page,
/// where it is started (``SavedWorkoutDetailView``).
struct MyWorkoutsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings
    @Query(sort: \SavedWorkout.updatedAt, order: .reverse) private var workouts: [SavedWorkout]
    @Query private var profiles: [UserProfile]

    @State private var editing: CustomWorkoutEditorView.Target?
    @State private var pendingDeletion: SavedWorkout?

    private var unit: UnitPreference { appSettings.unitPreference }

    private var trainingPaces: TrainingPaces? {
        guard let time = profiles.first?.currentEstimated5KTimeSeconds, time > 0 else { return nil }
        return PaceCalculatorService.trainingPaces(from5KTimeSeconds: time)
    }

    var body: some View {
        List {
            if workouts.isEmpty {
                StrideEmptyState(
                    "No workouts yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Build your own intervals, tempo blocks or fartlek, or start from one of the classics below.")
                ) {
                    Button("Build a workout") { editing = .new(CustomWorkoutDraft()) }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(workouts) { workout in
                        row(workout)
                    }
                }
                .strideListRow()
            }

            Section {
                ForEach(CustomWorkoutStarters.all(paces: trainingPaces, unit: unit)) { starter in
                    Button {
                        editing = .new(starter.draft)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: starter.draft.name)
                                .font(.dsBody.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(verbatim: starter.summary)
                                .font(.dsCaption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("myWorkouts.starter.\(starter.id)")
                }
            } header: {
                Text("Start from a classic")
            } footer: {
                if trainingPaces == nil {
                    Text("Add a recent race time in your profile and these come with your own paces.")
                }
            }
            .strideListRow()
        }
        .strideList()
        .navigationTitle("My workouts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = .new(CustomWorkoutDraft())
                } label: {
                    Label("Build a workout", systemImage: "plus")
                }
                .accessibilityIdentifier("myWorkouts.add")
            }
        }
        .sheet(item: $editing) { target in
            CustomWorkoutEditorView(target: target, trainingPaces: trainingPaces)
                .strideSheet()
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? String(localized: "this workout"))?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let workout = pendingDeletion {
                    context.delete(workout)
                    context.saveOrLog("the deletion of a custom workout")
                }
                pendingDeletion = nil
            }
        } message: {
            Text("Runs you did with it stay in your history.")
        }
    }

    private func row(_ workout: SavedWorkout) -> some View {
        NavigationLink {
            SavedWorkoutDetailView(workout: workout, trainingPaces: trainingPaces)
        } label: {
            SavedWorkoutRow(workout: workout, unit: unit)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDeletion = workout
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editing = .existing(workout) }
            Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(workout) }
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = workout }
        }
    }

    private func duplicate(_ workout: SavedWorkout) {
        guard let structure = workout.structure else { return }
        let name = String(localized: "\(workout.name) copy", comment: "Name of a duplicated custom workout")
        let copy = SavedWorkout(
            name: String(name.prefix(CustomWorkoutRules.maxNameLength)),
            structure: structure,
            notes: workout.notes
        )
        context.insert(copy)
        context.saveOrLog("the copy of a custom workout")
    }
}

// MARK: - Row

private struct SavedWorkoutRow: View {
    let workout: SavedWorkout
    let unit: UnitPreference

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            StrideIcon(name: .bolt, size: 16, color: .brand, strokeWeight: 2)
                .frame(width: 32, height: 32)
                .background(Color.brand.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: workout.name)
                    .font(.dsBody.weight(.semibold))
                    .foregroundStyle(.primary)
                if let structure = workout.structure {
                    let sets = CustomWorkoutSummary.setsLine(structure, unit: unit)
                    if !sets.isEmpty {
                        Text(verbatim: sets)
                            .font(.dsSubhead.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    if let totals = CustomWorkoutSummary.totalsLine(structure, unit: unit) {
                        Text(verbatim: totals)
                            .font(.dsCaption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
