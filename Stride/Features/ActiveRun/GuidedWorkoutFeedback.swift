import SwiftUI

// MARK: - GuidedWorkoutFeedback

/// Steps a structured workout forward as its targets are met, and (opt-in) calls each step
/// out loud — the guided half of what ``RunSplitFeedback`` does for splits.
///
/// Auto-advance used to live in `GuidedWorkoutBanner`, which only exists while the HUD is
/// on screen. Since a run can be minimised (U7) that meant a minimised interval session
/// stopped stepping: the rep's distance kept counting, but the stepper sat on it until the
/// HUD came back, and anything keyed to the step changing — the HUD haptic, and now the
/// spoken cue — never fired. A runner minimises precisely when the phone is going into a
/// pocket, which is when a spoken "Recover" matters most.
///
/// Applied twice, exactly like ``RunSplitFeedback`` and for the same reasons: by
/// `ActiveRunView` with `isActive: true` and by `MainTabView` with
/// `isActive: isRunMinimized`, so exactly one copy advances and speaks at a time. Nothing
/// here holds state of its own — the stepper lives on ``ActiveRunPresentation`` and the
/// heads-up fires on a crossing (see ``GuidedStepAnnouncement/headsUp(for:from:to:unit:)``)
/// — so handing over between the two copies loses nothing.
struct GuidedWorkoutFeedback: ViewModifier {

    /// Whether *this* copy owns advancing and speaking right now.
    let isActive: Bool

    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings

    private var tracker: WorkoutTrackerService { container.workoutTrackerService }
    private var presentation: ActiveRunPresentation { container.activeRunPresentation }

    /// The current step and how far through it the runner is — the value the heads-up
    /// watches, so a single `onChange` hands it the previous tick and this one together.
    private struct StepReading: Equatable {
        let stepNumber: Int
        let progress: GuidedStepProgress
    }

    private var stepReading: StepReading? {
        guard let guided = presentation.guided else { return nil }
        return StepReading(
            stepNumber: guided.stepNumber,
            progress: guided.progress(
                cumulativeDistanceMeters: tracker.distanceMeters,
                cumulativeElapsedSeconds: tracker.elapsedSeconds
            )
        )
    }

    // The closure signatures are spelled out for the same type-checker reason as the
    // HUD's own `sensoryFeedback` closures.
    func body(content: Content) -> some View {
        content
            // Distance-based steps settle on GPS/pedometer updates, time-based ones on the
            // per-second timer, so both signals are watched.
            .onChange(of: tracker.distanceMeters) { (_: Double, _: Double) in autoAdvanceIfNeeded() }
            .onChange(of: tracker.elapsedSeconds) { (_: Double, _: Double) in autoAdvanceIfNeeded() }
            // Every step change, automatic or the runner tapping Next, gets its cue.
            .onChange(of: presentation.guided?.stepNumber) { (oldStep: Int?, newStep: Int?) in
                guard isActive, let oldStep, let newStep, newStep != oldStep else { return }
                announceCurrentStep()
            }
            // Step 1 never *changes* to itself, so the warm-up is called when the run starts.
            .onChange(of: tracker.trackingState) { (oldState: TrackingState, newState: TrackingState) in
                guard isActive, oldState == .idle, newState == .active else { return }
                announceCurrentStep()
            }
            .onChange(of: stepReading) { (old: StepReading?, new: StepReading?) in
                guard isActive else { return }
                announceHeadsUpIfDue(from: old, to: new)
            }
    }

    // MARK: Advancing

    private func autoAdvanceIfNeeded() {
        // Only while recording: a paused runner has not finished the rep by standing
        // still, and the tracker's figures do not move then anyway.
        guard isActive,
              tracker.trackingState == .active,
              let guided = presentation.guided,
              guided.shouldAutoAdvance(
                  cumulativeDistanceMeters: tracker.distanceMeters,
                  cumulativeElapsedSeconds: tracker.elapsedSeconds
              ) else { return }
        presentation.guided?.advance(
            cumulativeDistanceMeters: tracker.distanceMeters,
            cumulativeElapsedSeconds: tracker.elapsedSeconds
        )
    }

    // MARK: Speaking

    /// Calls the step the runner is now in. Interrupting: a split still being read out
    /// when the rep changes is the sentence that has gone stale.
    private func announceCurrentStep() {
        guard appSettings.spokenWorkoutStepsEnabled,
              let guided = presentation.guided else { return }
        container.runVoiceCoach.speak(
            GuidedStepAnnouncement.stepStart(guided.currentStep, unit: appSettings.unitPreference),
            interrupting: true
        )
    }

    /// Speaks the end-of-step warning on the tick that crosses its threshold. Not
    /// interrupting: the one thing likely to be mid-sentence ten seconds from the end of
    /// a rep is that rep's own start cue on a very short step, which should finish.
    private func announceHeadsUpIfDue(from old: StepReading?, to new: StepReading?) {
        guard appSettings.spokenWorkoutStepsEnabled,
              tracker.trackingState == .active,
              let old, let new,
              old.stepNumber == new.stepNumber,
              let step = presentation.guided?.currentStep else { return }
        container.runVoiceCoach.speak(
            GuidedStepAnnouncement.headsUp(
                for: step,
                from: old.progress,
                to: new.progress,
                unit: appSettings.unitPreference
            )
        )
    }
}

extension View {
    /// Advances and (opt-in) speaks a guided workout's steps while `isActive`. See
    /// ``GuidedWorkoutFeedback`` for why this is applied by two views rather than one.
    func guidedWorkoutFeedback(isActive: Bool) -> some View {
        modifier(GuidedWorkoutFeedback(isActive: isActive))
    }
}
