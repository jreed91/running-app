import SwiftUI

/// In-run banner that guides a runner through a structured workout's steps
/// (warm-up → reps → recovery → cool-down).
///
/// It observes the ``WorkoutTrackerService`` directly so it refreshes on every
/// live distance/time tick — the environment `AppContainer` does not propagate
/// the tracker's `@Published` changes on its own. All stepping logic lives in
/// the pure ``GuidedWorkoutState`` (passed as a binding); this view only renders
/// it and forwards auto/manual advances.
struct GuidedWorkoutBanner: View {
    @ObservedObject var tracker: WorkoutTrackerService
    @Binding var guided: GuidedWorkoutState
    let unit: UnitPreference

    private var progress: GuidedStepProgress {
        guided.progress(
            cumulativeDistanceMeters: tracker.distanceMeters,
            cumulativeElapsedSeconds: tracker.elapsedSeconds
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stepTitle
            progressBar
            footer
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                )
        )
        .foregroundStyle(.white)
        // Auto-advance when the current step's distance/time target is met.
        // Distance-based steps settle on GPS/pedometer updates, time-based on the
        // per-second timer, so both signals are watched.
        .onChange(of: tracker.distanceMeters) { _, _ in autoAdvanceIfNeeded() }
        .onChange(of: tracker.elapsedSeconds) { _, _ in autoAdvanceIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(kindLabel.uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(1.6)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.16), in: Capsule())
            Spacer()
            Text("STEP \(guided.stepNumber) / \(guided.stepCount)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var kindLabel: String {
        let step = guided.currentStep
        if let index = step.repIndex, let count = step.repCount {
            return "\(step.label) · \(index)/\(count)"
        }
        return step.label
    }

    // MARK: - Step title & target

    private var stepTitle: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Text(targetText)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let pace = guided.currentStep.targetPaceSecondsPerKm, pace > 0 {
                Text("@ \(pace.paceString(unit: unit))")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    /// The primary remaining/target readout for the step.
    private var targetText: String {
        if let remaining = progress.remainingDistanceMeters {
            return remaining.distanceString(unit: unit) + " left"
        }
        if let remaining = progress.remainingSeconds {
            return remaining.durationString + " left"
        }
        return "Tap Next when done"
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.black.opacity(0.22))
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: max(6, geo.size.width * CGFloat(progress.fraction)))
                    .animation(.linear(duration: 0.2), value: progress.fraction)
            }
        }
        .frame(height: 8)
        // Open (no-target) steps have no determinate progress; dim the track.
        .opacity(guided.currentStep.isOpen ? 0.4 : 1)
    }

    // MARK: - Footer (next-up + advance control)

    private var footer: some View {
        HStack(spacing: 12) {
            if let next = guided.nextStep {
                VStack(alignment: .leading, spacing: 2) {
                    Text("UP NEXT")
                        .font(.system(size: 9, weight: .bold))
                        .kerning(1.2)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(next.label)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.9))
                }
            } else {
                Text("FINAL STEP")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            if !guided.isOnFinalStep {
                Button(action: advance) {
                    HStack(spacing: 6) {
                        Text("Next")
                            .font(.system(size: 14, weight: .bold))
                        Image(systemName: "forward.fill")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.18), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next step")
            }
        }
    }

    // MARK: - Advancement

    private func autoAdvanceIfNeeded() {
        // Derived from the observed tracker rather than a parent-passed flag: the
        // parent view does not reliably re-render on tracker state changes, but
        // this view observes the tracker directly so its state is always current.
        guard tracker.trackingState == .active else { return }
        if guided.shouldAutoAdvance(
            cumulativeDistanceMeters: tracker.distanceMeters,
            cumulativeElapsedSeconds: tracker.elapsedSeconds
        ) {
            advance()
        }
    }

    private func advance() {
        guided.advance(
            cumulativeDistanceMeters: tracker.distanceMeters,
            cumulativeElapsedSeconds: tracker.elapsedSeconds
        )
    }
}
