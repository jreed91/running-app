import SwiftUI

struct MainTabView: View {
    @Environment(\.appContainer) private var container

    /// Taken from the container once and cleared there, so the notice drives this
    /// alert from local state and cannot reappear if the tab bar is rebuilt.
    @State private var recoveryNotice: AppContainer.StoreRecoveryNotice?

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
            PlanTabView()
                .tabItem {
                    Label("Plan", systemImage: "calendar")
                }
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            ProgressDashboardView()
                .tabItem {
                    Label("Progress", systemImage: "chart.line.uptrend.xyaxis")
                }
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .tint(.brand)
        .accessibilityIdentifier("main.tabs")
        // A store that had to be recovered used to be visible only as a line of text
        // buried in Settings, so a user whose data failed to migrate just saw an empty
        // app. Surface it once, at the root, on the launch it happens (C3).
        .task {
            guard let notice = container.storeRecoveryNotice else { return }
            container.storeRecoveryNotice = nil
            recoveryNotice = notice
        }
        .alert(
            recoveryNotice?.title ?? "",
            isPresented: Binding(
                get: { recoveryNotice != nil },
                set: { if !$0 { recoveryNotice = nil } }
            ),
            presenting: recoveryNotice
        ) { _ in
            Button("OK", role: .cancel) { recoveryNotice = nil }
        } message: { notice in
            Text(notice.message)
        }
    }
}
