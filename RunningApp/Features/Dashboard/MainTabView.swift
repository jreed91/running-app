import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                DashboardView()
            }
            Tab("Plan", systemImage: "calendar") {
                TrainingPlanListView()
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
    }
}
