import SwiftUI
import SwiftData

@main
struct RunningAppApp: App {

    @StateObject private var container = AppContainer()
    @State private var appSettings = AppSettings()
    @State private var authService = AuthService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.appContainer, container)
                .environment(appSettings)
                .environment(authService)
                .modelContainer(container.modelContainer)
                .task {
                    await container.workoutSyncService.startObserving()
                    await authService.checkCredentialState()
                }
        }
    }
}

// MARK: - Root view

/// Switches between onboarding and the main tab bar.
/// `welcomeBackPending` keeps OnboardingView visible while the returning-user
/// screen is displayed, even after CloudKit delivers the user's profiles.
struct ContentView: View {
    @Environment(AuthService.self) private var authService
    @Query private var profiles: [UserProfile]

    var body: some View {
        if profiles.isEmpty || authService.welcomeBackPending {
            OnboardingView()
        } else {
            MainTabView()
        }
    }
}
