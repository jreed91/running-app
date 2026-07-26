import SwiftUI

struct MainTabView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings

    /// The run HUD is a `fullScreenCover`, so a runner who dismisses it to check the
    /// plan or their history leaves a workout recording with nothing on screen saying
    /// so. `tabViewBottomAccessory` is the system's answer to exactly this (the Now
    /// Playing pattern): the run stays visible above the tab bar on every tab, and
    /// tapping it brings the HUD back (U7).
    private var isRunLive: Bool {
        switch container.workoutTrackerService.trackingState {
        case .active, .paused: true
        case .idle, .finished: false
        }
    }

    var body: some View {
        // `Tab` rather than `.tabItem` — the builder form has been the correct one
        // since iOS 18, well below this app's 27.0 floor, and it is what the newer
        // tab-bar behaviours (minimize, bottom accessory) attach to (U7).
        TabView {
            Tab("Home", systemImage: "house.fill") {
                DashboardView()
            }
            Tab("Plan", systemImage: "calendar") {
                PlanTabView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath") {
                HistoryView()
            }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis") {
                ProgressDashboardView()
            }
            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
        }
        .tint(.brand)
        .accessibilityIdentifier("main.tabs")
        // Gives content the full height on scroll down; the bar returns on scroll up.
        // Paired with the accessory below, which minimizes alongside the bar rather
        // than disappearing — a live run stays reachable in both states.
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if isRunLive {
                ActiveRunAccessory()
            }
        }
        // Each closed kilometre/mile, spoken (U4). This observer used to live in
        // `ActiveRunView`, where it died with the screen — so the moment the runner
        // minimized the HUD and pocketed the phone, the feature that exists for exactly
        // that moment went quiet. `MainTabView` is mounted for the whole session and the
        // tracker is a container singleton, so one observer here covers both states.
        .onChange(of: container.workoutTrackerService.splits.count) { oldCount, newCount in
            announceSplit(previousCount: oldCount, count: newCount)
        }
        // The store-recovery alert (C3) is presented by `ContentView`, not here: a
        // recreated store has no profile, so the app shows onboarding and this view
        // never appears on exactly the launch the notice describes (N5).
    }

    /// Speaks the split that just closed, when the runner has asked for it.
    ///
    /// Off by default (`AppSettings.spokenSplitsEnabled`) — this is the one feature that
    /// talks over whatever else is playing.
    private func announceSplit(previousCount: Int, count: Int) {
        guard appSettings.spokenSplitsEnabled,
              count > previousCount,
              let split = container.workoutTrackerService.splits.last else { return }
        container.runVoiceCoach.speak(
            SplitAnnouncement.phrase(
                splitNumber: split.kilometer,
                paceSecondsPerKm: split.paceSecondsPerKm,
                unit: appSettings.unitPreference,
                targetPaceSecondsPerKm: container.activeRunTargetPaceBand
            )
        )
    }
}

// MARK: - Active run accessory

/// The live-run bar that sits above the tab bar while a workout is recording.
///
/// Reads the tracker directly: it is `@Observable`, so touching `elapsedSeconds` and
/// `distanceMeters` in `body` is what keeps this ticking (D4).
private struct ActiveRunAccessory: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var tracker: WorkoutTrackerService { container.workoutTrackerService }

    private var isPaused: Bool { tracker.trackingState == .paused }

    private var elapsed: String { tracker.elapsedSeconds.durationString }

    private var distance: String {
        tracker.distanceMeters.distanceString(unit: appSettings.unitPreference)
    }

    var body: some View {
        Button {
            container.isShowingActiveRun = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPaused ? "pause.circle.fill" : "figure.run.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(isPaused ? Color.warning : Color.brand)
                    // Carries "recording" vs "paused" in motion as well as colour, which
                    // is what Differentiate Without Color needs from a status glyph (§3d).
                    .symbolEffect(.pulse, isActive: !isPaused)

                // Collapsed, the accessory is roughly a third of the width — the clock
                // is the one number worth keeping there.
                if placement == .inline {
                    Text(elapsed)
                        .font(.dsSubhead.monospacedDigit())
                        .lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isPaused ? "Run paused" : "Run in progress")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                        Text("\(elapsed) · \(distance)")
                            .font(.dsSubhead.monospacedDigit())
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isPaused ? "Run paused" : "Run in progress")
        .accessibilityValue("\(elapsed), \(distance)")
        .accessibilityHint("Opens the run screen.")
        .accessibilityIdentifier("main.tabs.activeRunAccessory")
    }
}
