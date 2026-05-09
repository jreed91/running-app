import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Home", strideIcon: .home)
                }
            PlanTabView()
                .tabItem {
                    Label("Plan", strideIcon: .calendar)
                }
            HistoryView()
                .tabItem {
                    Label("History", strideIcon: .history)
                }
            ProgressDashboardView()
                .tabItem {
                    Label("Progress", strideIcon: .chart)
                }
            SettingsView()
                .tabItem {
                    Label("Settings", strideIcon: .gear)
                }
        }
        .tint(.brand)
        .accessibilityIdentifier("main.tabs")
    }
}
