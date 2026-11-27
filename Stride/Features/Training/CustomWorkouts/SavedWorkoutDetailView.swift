import SwiftData
import SwiftUI

// MARK: - SavedWorkoutDetailView

/// One of the runner's own workouts: its steps, its estimate and a Start button
/// (Custom workouts, PR 3).
///
/// Start opens the same run screen a plan session does, with the guided banner and spoken
/// steps, through ``ActiveRunPresentation/startOrReopen(customRun:isRunInProgress:)``. A
/// run already recording is reopened rather than replaced, as every other start control
/// does.
struct SavedWorkoutDetailView: View {
    let workout: SavedWorkout
    let trainingPaces: TrainingPaces?

    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings

    @State private var editing: CustomWorkoutEditorView.Target?

    private var unit: UnitPreference { appSettings.unitPreference }
    private var isRunInProgress: Bool { container.workoutTrackerService.isRecording }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                header
                if let structure = workout.structure {
                    steps(structure)
                }
                if let notes = workout.notes, !notes.isEmpty {
                    Text(verbatim: notes)
                        .font(.dsSubhead)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppSpacing.lg)
                        .strideCard()
                }
                startButton
            }
            .padding(AppSpacing.lg)
        }
        .background(Color.surfacePrimary)
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = .existing(workout) }
                    .accessibilityIdentifier("savedWorkout.edit")
            }
        }
        .sheet(item: $editing) { target in
            // No Delete here: this page would be left showing a deleted model, and reading
            // one crashes. The library's swipe and its own editor delete.
            CustomWorkoutEditorView(target: target, trainingPaces: trainingPaces, allowsDelete: false)
                .strideSheet()
        }
    }

    @ViewBuilder
    private var header: some View {
        if let structure = workout.structure {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                let sets = CustomWorkoutSummary.setsLine(structure, unit: unit)
                if !sets.isEmpty {
                    Text(verbatim: sets)
                        .font(.title2.weight(.bold).monospacedDigit())
                }
                if let totals = CustomWorkoutSummary.totalsLine(structure, unit: unit) {
                    Text(verbatim: totals)
                        .font(.dsSubhead.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func steps(_ structure: WorkoutStructure) -> some View {
        let rows = PlannedStep.steps(from: structure, unit: unit)
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Divider().padding(.leading, 26)
                }
                PlannedStepRow(step: step)
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.xs)
        .strideCard()
    }

    private var startButton: some View {
        Button {
            start()
        } label: {
            HStack(spacing: 10) {
                StrideIcon(name: .play, size: 18, color: .onFill, strokeWeight: 2.2)
                Text(isRunInProgress ? "Back to your run" : "Start this workout")
            }
        }
        .buttonStyle(.strideButton())
        .disabled(workout.structure == nil)
        .accessibilityIdentifier("savedWorkout.start")
    }

    private func start() {
        guard let structure = workout.structure else { return }
        if !isRunInProgress {
            workout.markUsed()
            context.saveOrLog("the use of a custom workout")
        }
        container.activeRunPresentation.startOrReopen(
            customRun: .init(id: workout.id, name: workout.name, structure: structure),
            isRunInProgress: isRunInProgress
        )
    }
}
