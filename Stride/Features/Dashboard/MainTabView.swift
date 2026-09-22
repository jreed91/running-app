import SwiftUI

struct MainTabView: View {
    @Environment(AppContainer.self) private var container

    private var presentation: ActiveRunPresentation { container.activeRunPresentation }

    /// A run is minimised when the tracker is recording and the HUD is closed. Anything
    /// else — no run at all, or the HUD on screen over the top of this view — hides the
    /// accessory.
    private var isRunMinimized: Bool {
        !presentation.isPresented && container.workoutTrackerService.isRecording
    }

    var body: some View {
        // `Tab` rather than `.tabItem` — the builder form has been the correct one
        // since iOS 18, well below this app's 27.0 floor, and it is what the newer
        // tab-bar behaviours (minimize, bottom accessory) attach to (U7).
        //
        // The selection is bound rather than left to `TabView`'s own state because a
        // widget tapped on the Home Screen has to be able to land on the right tab, and
        // that decision is made at the scene root (B1).
        TabView(selection: selectedTab) {
            Tab("Home", systemImage: "house.fill", value: StrideTab.home) {
                DashboardView()
            }
            Tab("Plan", systemImage: "calendar", value: StrideTab.plan) {
                PlanTabView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: StrideTab.history) {
                HistoryView()
            }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis", value: StrideTab.progress) {
                ProgressDashboardView()
            }
            Tab("Settings", systemImage: "gear", value: StrideTab.settings) {
                SettingsView()
            }
        }
        .tint(.brand)
        .accessibilityIdentifier("main.tabs")
        // The tab bar collapses out of the way as the runner scrolls into a plan week or
        // a season of history, and comes back on the way up (U7).
        .tabBarMinimizeBehavior(.onScrollDown)
        // A recording run, minimised. `isEnabled:` rather than a conditional inside the
        // builder: it is the documented way to show and hide an accessory, and it lets
        // the accessory animate in and out rather than appear.
        .tabViewBottomAccessory(isEnabled: isRunMinimized) {
            ActiveRunAccessory()
        }
        // The run HUD is presented here, not by `DashboardView`, and that is what makes
        // minimising possible: a cover owned by the Home tab could only be left by
        // finishing or discarding the run, and it covered the accessory that now offers
        // the way back (U7).
        .fullScreenCover(isPresented: isRunPresented) {
            ActiveRunView()
        }
        // A closed split has to be felt and heard whether or not the HUD is on screen, and
        // while the run is minimised this view is the only one left to say so (U4/U7). The
        // HUD carries the same modifier with `isActive: true`, so the two never both fire.
        .runSplitFeedback(isActive: isRunMinimized)
        // Likewise a guided workout's steps: advancing them, and calling them out, has to
        // carry on while the run is minimised — see `GuidedWorkoutFeedback`.
        .guidedWorkoutFeedback(isActive: isRunMinimized)
        // The store-recovery alert (C3) is presented by `ContentView`, not here: a
        // recreated store has no profile, so the app shows onboarding and this view
        // never appears on exactly the launch the notice describes (N5).
    }

    /// Read and written straight through to `AppNavigation` for the same reason
    /// `isRunPresented` is: one owner, so a deep link and the tab bar cannot end up
    /// disagreeing about which tab is showing.
    private var selectedTab: Binding<StrideTab> {
        Binding(
            get: { container.appNavigation.selectedTab },
            set: { container.appNavigation.selectedTab = $0 }
        )
    }

    /// `ActiveRunPresentation` is `@Observable`, so this reads and writes it directly
    /// rather than mirroring it into `@State`: one owner, so the accessory and the HUD
    /// can never disagree about whether the run is minimised.
    private var isRunPresented: Binding<Bool> {
        Binding(
            get: { presentation.isPresented },
            set: { presentation.isPresented = $0 }
        )
    }
}
