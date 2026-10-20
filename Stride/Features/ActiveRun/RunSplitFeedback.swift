import SwiftUI

// MARK: - RunSplitFeedback

/// The per-split haptic (U4), attached to wherever the run is currently being watched
/// rather than to one screen.
///
/// The spoken announcement used to live here too; it moved to ``RunSpokenCues``, which
/// listens to the tracker, because a locked phone updates no views and the split went
/// unsaid exactly when it was wanted. A haptic needs a view on screen anyway.
///
/// Applied twice — by `ActiveRunView` with `isActive: true`, and by `MainTabView` with
/// `isActive: isRunMinimized` — which makes the two mutually exclusive, so a split is
/// felt exactly once. That is deliberately not "apply it once, high up": whether
/// `sensoryFeedback` fires for a view sitting underneath a `fullScreenCover` is not
/// documented either way, and finding out by losing the HUD's split haptic would be a
/// regression in a shipped feature.
struct RunSplitFeedback: ViewModifier {

    /// Whether *this* copy owns the haptic right now.
    let isActive: Bool

    @Environment(AppContainer.self) private var container

    private var tracker: WorkoutTrackerService { container.workoutTrackerService }

    func body(content: Content) -> some View {
        content
            // Each completed kilometre/mile, so pace checks don't need a glance.
            .sensoryFeedback(.impact(weight: .light), trigger: tracker.splits.count) { old, new in
                isActive && new > old
            }
    }
}

extension View {
    /// Feels each closed split while `isActive`. See ``RunSplitFeedback`` for why this is
    /// applied by two views rather than one.
    func runSplitFeedback(isActive: Bool) -> some View {
        modifier(RunSplitFeedback(isActive: isActive))
    }
}
