import SwiftUI

struct MainTabView: View {
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
        // The store-recovery alert (C3) is presented by `ContentView`, not here: a
        // recreated store has no profile, so the app shows onboarding and this view
        // never appears on exactly the launch the notice describes (N5).
    }
}
