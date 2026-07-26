import SwiftUI

// MARK: - RunSplitFeedback

/// The per-split haptic and spoken announcement (U4), attached to wherever the run is
/// currently being watched rather than to one screen.
///
/// Both of these started life as modifiers on the run HUD, which was correct while the HUD
/// was the only place a run could be — it was a `fullScreenCover` with no way out. Since a
/// run can be minimised (U7) it outlives that screen, and a closing kilometre has to be
/// felt and heard either way: a runner minimises precisely when the phone is going into a
/// pocket.
///
/// Applied twice — by `ActiveRunView` with `isActive: true`, and by `MainTabView` with
/// `isActive: isRunMinimized` — which makes the two mutually exclusive, so a split is
/// announced exactly once. That is deliberately not "apply it once, high up": whether
/// `sensoryFeedback` fires for a view sitting underneath a `fullScreenCover` is not
/// documented either way, and finding out by losing the HUD's split haptic would be a
/// regression in a shipped feature.
struct RunSplitFeedback: ViewModifier {

    /// Whether *this* copy owns the announcement right now.
    let isActive: Bool

    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings

    private var tracker: WorkoutTrackerService { container.workoutTrackerService }

    func body(content: Content) -> some View {
        content
            // Each completed kilometre/mile, so pace checks don't need a glance.
            .sensoryFeedback(.impact(weight: .light), trigger: tracker.splits.count) { old, new in
                isActive && new > old
            }
            // The light haptic above says *that* a split closed; only speech can say what it
            // was, which is the whole reason a runner would look at the phone mid-stride.
            .onChange(of: tracker.splits.count) { (oldCount: Int, newCount: Int) in
                guard isActive else { return }
                announceSplit(previousCount: oldCount, count: newCount)
            }
    }

    /// Speaks the split that just closed, when the runner has asked for it.
    ///
    /// Off by default (`AppSettings.spokenSplitsEnabled`) — this is the one feature that
    /// talks over whatever else is playing.
    private func announceSplit(previousCount: Int, count: Int) {
        guard appSettings.spokenSplitsEnabled,
              count > previousCount,
              let split = tracker.splits.last else { return }
        container.runVoiceCoach.speak(
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
        let presentation = container.activeRunPresentation
        if let stepPace = presentation.guided?.currentStep.targetPaceSecondsPerKm, stepPace > 0 {
            return stepPace...stepPace
        }
        return presentation.scheduledWorkout?.targetPaceRange
    }
}

extension View {
    /// Feels and speaks each closed split while `isActive`. See ``RunSplitFeedback`` for why
    /// this is applied by two views rather than one.
    func runSplitFeedback(isActive: Bool) -> some View {
        modifier(RunSplitFeedback(isActive: isActive))
    }
}
