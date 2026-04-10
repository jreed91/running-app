import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            TrainingPlanListView()
                .tabItem { Label("Plan", systemImage: "calendar") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            ProgressDashboardView()
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
