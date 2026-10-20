import SwiftUI

/// In-run banner that guides a runner through a structured workout's steps
/// (warm-up → reps → recovery → cool-down).
///
/// It reads the ``WorkoutTrackerService`` directly so it refreshes on every live
/// distance/time tick; the tracker is `@Observable`, so reading it in `body` is the
/// subscription. All stepping logic lives in the pure ``GuidedWorkoutState`` (passed as
/// a binding); this view only renders it and forwards the runner's manual "Next".
///
/// Auto-advance is not here: it is ``RunSpokenCues``'s, which keeps stepping from the
/// tracker's tick while the run is minimised or the phone is locked.
struct GuidedWorkoutBanner: View {
    let tracker: WorkoutTrackerService
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
        .glassEffect(.regular, in: .rect(cornerRadius: AppRadius.xl))
        .foregroundStyle(.white)
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
                .foregroundStyle(.white.opacity(0.92))
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
                    .foregroundStyle(.white.opacity(0.92))
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
        // `GeometryReader` stays here deliberately (U7). `ProgressView(value:)` retired the
        // two onboarding chrome bars, which were already the platform's 4pt track drawn by
        // hand — this one is an 8pt capsule with a 6pt minimum fill on a saturated zone
        // gradient, so swapping it would be a redesign of the run HUD rather than adopting a
        // component that matches.
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
                        // 9pt, under Apple's legibility floor, at 0.55 white over a
                        // saturated zone gradient — 1.5:1 (U2/U3b).
                        .font(.metricLabel)
                        .kerning(1.2)
                        .foregroundStyle(.white.opacity(0.92))
                    Text(next.label)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.95))
                }
            } else {
                Text("FINAL STEP")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(.white.opacity(0.92))
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
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.18), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                    // The capsule is ~35pt tall; the tap target is the 44pt minimum,
                    // which matters most mid-stride.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next step")
            }
        }
    }

    // MARK: - Advancement

    private func advance() {
        guided.advance(
            cumulativeDistanceMeters: tracker.distanceMeters,
            cumulativeElapsedSeconds: tracker.elapsedSeconds
        )
    }
}
