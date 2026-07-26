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
        // The store-recovery alert (C3) is presented by `ContentView`, not here: a
        // recreated store has no profile, so the app shows onboarding and this view
        // never appears on exactly the launch the notice describes (N5).
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
