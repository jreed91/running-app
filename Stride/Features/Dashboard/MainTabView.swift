import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label {
                        Text("Home")
                    } icon: {
                        Image(uiImage: StrideIconName.home.uiImage())
                    }
                }
            PlanTabView()
                .tabItem {
                    Label {
                        Text("Plan")
                    } icon: {
                        Image(uiImage: StrideIconName.calendar.uiImage())
                    }
                }
            HistoryView()
                .tabItem {
                    Label {
                        Text("History")
                    } icon: {
                        Image(uiImage: StrideIconName.history.uiImage())
                    }
                }
            ProgressDashboardView()
                .tabItem {
                    Label {
                        Text("Progress")
                    } icon: {
                        Image(uiImage: StrideIconName.chart.uiImage())
                    }
                }
            SettingsView()
                .tabItem {
                    Label {
                        Text("Settings")
                    } icon: {
                        Image(uiImage: StrideIconName.gear.uiImage())
                    }
                }
        }
        .tint(.brand)
        .accessibilityIdentifier("main.tabs")
    }
}
