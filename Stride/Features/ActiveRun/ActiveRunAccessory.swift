import SwiftUI

// MARK: - ActiveRunAccessory

/// A recording run, minimised into the tab-bar accessory (U7).
///
/// `MainTabView` shows this whenever the tracker is recording and the HUD is closed, so
/// it is the whole of the run while the runner is somewhere else in the app: it has to
/// prove the run is still going, and it has to be the way back. Tapping the row reopens
/// the HUD; the trailing control is pause/resume, which is the one thing worth doing
/// without reopening — the same shape as the system's Now Playing accessory.
///
/// Deliberately one line and static. This sits above the tab bar on every screen, so it
/// gets no pulse, no animation and no second row: an accessory that draws the eye
/// continuously would be worse than the `fullScreenCover` it replaces.
struct ActiveRunAccessory: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings

    private var tracker: WorkoutTrackerService { container.workoutTrackerService }
    private var presentation: ActiveRunPresentation { container.activeRunPresentation }
    private var isPaused: Bool { tracker.trackingState == .paused }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                presentation.reopen()
            } label: {
                summaryRow
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spokenLabel)
            .accessibilityHint("Opens the run screen")
            .accessibilityIdentifier("activeRun.accessory.reopen")

            pauseResumeButton
        }
        .padding(.leading, 14)
        .padding(.trailing, AppSpacing.xs)
        // The HUD's own pause/resume haptic goes with the HUD, and a run is minimised
        // precisely when the phone is in a pocket — the state change has to be felt.
        .sensoryFeedback(.selection, trigger: tracker.trackingState)
    }

    private var summaryRow: some View {
        HStack(spacing: 10) {
            StrideIcon(name: .run, size: 16, color: .brand, strokeWeight: 2.2)
            Text(title)
                .font(.dsSubhead.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        // Without this the tap target is the text's own bounds, so the empty half of
        // the accessory does nothing.
        .contentShape(Rectangle())
    }

    private var pauseResumeButton: some View {
        Button {
            if isPaused {
                tracker.resumeWorkout()
            } else {
                tracker.pauseWorkout()
            }
        } label: {
            StrideIcon(
                name: isPaused ? .play : .pause,
                size: 17,
                color: .brand,
                strokeWeight: 2.2
            )
            // 44pt, not the glyph's 17: this is a one-handed tap while running (U10).
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused ? "Resume run" : "Pause run")
        .accessibilityIdentifier("activeRun.accessory.pauseResume")
    }

    private var title: String {
        MinimizedRunSummary.title(
            state: tracker.trackingState,
            elapsedSeconds: tracker.elapsedSeconds,
            distanceMeters: tracker.distanceMeters,
            unit: appSettings.unitPreference
        )
    }

    private var spokenLabel: String {
        MinimizedRunSummary.spokenLabel(
            state: tracker.trackingState,
            elapsedSeconds: tracker.elapsedSeconds,
            distanceMeters: tracker.distanceMeters,
            unit: appSettings.unitPreference
        )
    }
}
