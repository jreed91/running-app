import SwiftUI
import SwiftData

@main
struct RunningAppApp: App {

    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.appContainer, container)
                .modelContainer(container.modelContainer)
                .task {
                    // Request permissions on first launch — non-blocking.
                    try? await container.healthKitRepository.requestAuthorization()
                    try? await container.notificationService.requestAuthorization()
                }
        }
    }
}

// MARK: - Root view

/// Switches between onboarding and the main tab bar.
struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]

    var body: some View {
        if profiles.isEmpty {
            OnboardingView()
        } else {
            MainTabView()
        }
    }
}
