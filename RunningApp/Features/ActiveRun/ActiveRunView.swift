import SwiftUI

struct ActiveRunView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var showFinishConfirmation = false

    private var tracker: WorkoutTrackerService { container.workoutTrackerService }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                // Primary metrics
                VStack(spacing: 8) {
                    metricBlock(
                        value: tracker.distanceMeters.distanceKmString,
                        label: "DISTANCE"
                    )
                    HStack(spacing: 48) {
                        metricBlock(
                            value: tracker.elapsedSeconds.durationString,
                            label: "TIME"
                        )
                        metricBlock(
                            value: tracker.currentPaceSecondsPerKm.paceString,
                            label: "PACE"
                        )
                    }
                }
                .foregroundStyle(.white)

                Spacer()

                // Controls
                HStack(spacing: 40) {
                    if tracker.trackingState == .active {
                        controlButton(icon: "pause.fill", color: .orange) {
                            tracker.pauseWorkout()
                        }
                    } else if tracker.trackingState == .paused {
                        controlButton(icon: "play.fill", color: .green) {
                            tracker.resumeWorkout()
                        }
                    }

                    controlButton(icon: "stop.fill", color: .red) {
                        showFinishConfirmation = true
                    }
                }
                .padding(.bottom, 48)
            }
            .padding()
        }
        .onAppear {
            if tracker.trackingState == .idle {
                tracker.startWorkout(type: .easy)
            }
        }
        .confirmationDialog("Finish workout?", isPresented: $showFinishConfirmation, titleVisibility: .visible) {
            Button("Finish", role: .destructive) { finishAndSave() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Subviews

    private func metricBlock(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.metricLarge)
            Text(label).font(.sectionHeader).foregroundStyle(.secondary)
        }
    }

    private func controlButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(color, in: Circle())
        }
    }

    // MARK: Actions

    private func finishAndSave() {
        guard let workout = tracker.finishWorkout() else { dismiss(); return }
        context.insert(workout)
        try? context.save()
        Task {
            try? await container.healthKitRepository.save(workout)
        }
        dismiss()
    }
}
