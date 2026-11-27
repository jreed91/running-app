import SwiftData
import SwiftUI

// MARK: - SwapForCustomWorkoutSheet

/// Picks one of the runner's own workouts to run on a plan day instead of what the plan
/// had (Custom workouts, PR 4). The caller applies it; this only chooses.
struct SwapForCustomWorkoutSheet: View {
    /// The session being replaced, for the explanation under the list.
    let sessionTitle: String
    let onPick: (SavedWorkout) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var appSettings
    @Query(sort: \SavedWorkout.updatedAt, order: .reverse) private var workouts: [SavedWorkout]

    private var unit: UnitPreference { appSettings.unitPreference }
    private var runnable: [SavedWorkout] { workouts.filter { $0.structure != nil } }

    var body: some View {
        NavigationStack {
            List {
                if runnable.isEmpty {
                    StrideEmptyState(
                        "No workouts yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Build one in Plan › My workouts, then swap it in here.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(runnable) { workout in
                            Button {
                                onPick(workout)
                                dismiss()
                            } label: {
                                row(workout)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("It replaces \(sessionTitle) on this day. The day stays where it is in your week.")
                    }
                    .strideListRow()
                }
            }
            .strideList()
            .navigationTitle("Swap for a workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    private func row(_ workout: SavedWorkout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: workout.name)
                .font(.dsBody.weight(.semibold))
                .foregroundStyle(.primary)
            if let structure = workout.structure {
                let sets = CustomWorkoutSummary.setsLine(structure, unit: unit)
                let totals = CustomWorkoutSummary.totalsLine(structure, unit: unit)
                Text(verbatim: [sets, totals].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.dsCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityAddTraits(.isButton)
    }
}
