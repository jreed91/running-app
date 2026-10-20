import Foundation

// MARK: - RunSpokenCues

/// Speaks each closed split and each guided-workout cue, and steps a structured workout on
/// as its targets are met — driven by the tracker's pulse, not by a view.
///
/// This used to live in two view modifiers (`RunSplitFeedback` and `GuidedWorkoutFeedback`)
/// reacting with `onChange`. That held while the screen was on, but those cues exist for
/// the phone in a pocket, and a locked phone updates no views: the split closed, the rep
/// ended, and nothing was said. App Review heard exactly that silence (2.5.4). The tracker
/// keeps running in the background on the location mode, so its per-second tick is the
/// pulse this listens to — the same move `RunRouteGuide` made for the off-route warning.
///
/// Everything here works from the tracker and `ActiveRunPresentation`, which outlive any
/// screen, so a minimised run and a locked phone behave the same as the HUD.
@MainActor
final class RunSpokenCues {

    private let tracker: WorkoutTrackerService
    private let presentation: ActiveRunPresentation
    private let voiceCoach: RunVoiceCoach

    /// Read for the opt-ins and the unit. Set once at launch by `StrideApp`, which owns
    /// the instance; `nil` (unit tests, previews) still advances steps but says nothing.
    weak var appSettings: AppSettings?

    /// The current step and how far through it the runner is, as of the previous tick.
    private struct StepReading: Equatable {
        let stepNumber: Int
        let progress: GuidedStepProgress
    }

    private var lastSplitCount = 0
    private var lastStepNumber: Int?
    private var lastReading: StepReading?

    init(tracker: WorkoutTrackerService, presentation: ActiveRunPresentation, voiceCoach: RunVoiceCoach) {
        self.tracker = tracker
        self.presentation = presentation
        self.voiceCoach = voiceCoach
    }

    /// One pulse from the tracker.
    func handle(_ pulse: WorkoutTrackerService.Pulse) {
        switch pulse {
        case .started:
            lastSplitCount = 0
            lastStepNumber = presentation.guided?.stepNumber
            lastReading = currentReading
            // Step 1 never *changes* to itself, so the warm-up is called when the run starts.
            announceCurrentStep()
        case .tick:
            autoAdvanceIfNeeded()
            announceSplitIfClosed()
            announceStepChangeIfAny()
            let reading = currentReading
            announceHeadsUpIfDue(from: lastReading, to: reading)
            lastReading = reading
        }
    }

    // MARK: Advancing

    private func autoAdvanceIfNeeded() {
        // Ticks only arrive while recording, so a paused runner has not finished the rep
        // by standing still.
        guard let guided = presentation.guided,
              guided.shouldAutoAdvance(
                  cumulativeDistanceMeters: tracker.distanceMeters,
                  cumulativeElapsedSeconds: tracker.elapsedSeconds
              ) else { return }
        presentation.guided?.advance(
            cumulativeDistanceMeters: tracker.distanceMeters,
            cumulativeElapsedSeconds: tracker.elapsedSeconds
        )
    }

    // MARK: Splits

    /// Speaks the split that just closed, when the runner has asked for it.
    ///
    /// Off by default (`AppSettings.spokenSplitsEnabled`) — this is the one feature that
    /// talks over whatever else is playing.
    private func announceSplitIfClosed() {
        let count = tracker.splits.count
        defer { lastSplitCount = count }
        guard count > lastSplitCount,
              let appSettings, appSettings.spokenSplitsEnabled,
              let split = tracker.splits.last else { return }
        voiceCoach.speak(
            SplitAnnouncement.phrase(
                splitNumber: split.kilometer,
                paceSecondsPerKm: split.paceSecondsPerKm,
                unit: appSettings.unitPreference,
                targetPaceSecondsPerKm: targetBand
            )
        )
    }

    /// The pace band a split is judged against, narrowest first: the guided step the runner
    /// is actually in, then the scheduled workout's own target. A free run has neither, and
    /// its splits are announced without a verdict.
    private var targetBand: ClosedRange<Double>? {
        if let stepPace = presentation.guided?.currentStep.targetPaceSecondsPerKm, stepPace > 0 {
            return stepPace...stepPace
        }
        return presentation.scheduledWorkout?.targetPaceRange
    }

    // MARK: Guided steps

    private var currentReading: StepReading? {
        guard let guided = presentation.guided else { return nil }
        return StepReading(
            stepNumber: guided.stepNumber,
            progress: guided.progress(
                cumulativeDistanceMeters: tracker.distanceMeters,
                cumulativeElapsedSeconds: tracker.elapsedSeconds
            )
        )
    }

    /// Every step change, automatic or the runner tapping Next, gets its cue — at most a
    /// second after a tap, since the tap is caught on the next tick.
    private func announceStepChangeIfAny() {
        let stepNumber = presentation.guided?.stepNumber
        defer { lastStepNumber = stepNumber }
        guard let stepNumber, let lastStepNumber, stepNumber != lastStepNumber else { return }
        announceCurrentStep()
    }

    /// Calls the step the runner is now in. Interrupting: a split still being read out
    /// when the rep changes is the sentence that has gone stale.
    private func announceCurrentStep() {
        guard let appSettings, appSettings.spokenWorkoutStepsEnabled,
              let guided = presentation.guided else { return }
        voiceCoach.speak(
            GuidedStepAnnouncement.stepStart(guided.currentStep, unit: appSettings.unitPreference),
            interrupting: true
        )
    }

    /// Speaks the end-of-step warning on the tick that crosses its threshold. Not
    /// interrupting: the one thing likely to be mid-sentence ten seconds from the end of
    /// a rep is that rep's own start cue on a very short step, which should finish.
    private func announceHeadsUpIfDue(from old: StepReading?, to new: StepReading?) {
        guard let appSettings, appSettings.spokenWorkoutStepsEnabled,
              let old, let new,
              old.stepNumber == new.stepNumber,
              let step = presentation.guided?.currentStep else { return }
        voiceCoach.speak(
            GuidedStepAnnouncement.headsUp(
                for: step,
                from: old.progress,
                to: new.progress,
                unit: appSettings.unitPreference
            )
        )
    }
}
