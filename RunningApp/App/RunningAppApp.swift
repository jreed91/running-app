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
    @Environment(\.modelContext) private var context
    @Environment(AuthService.self) private var authService

    // Sorted oldest-first so dedup always keeps the record with the most history.
    @Query(sort: \UserProfile.createdAt, order: .forward)
    private var profiles: [UserProfile]

    // Sorted newest-first so dedup keeps the most current active plan.
    @Query(
        filter: #Predicate<TrainingPlan> { $0.isActive },
        sort: \TrainingPlan.createdAt, order: .reverse
    )
    private var activePlans: [TrainingPlan]

    var body: some View {
        Group {
            if profiles.isEmpty || authService.welcomeBackPending {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .task { deduplicate() }
        .onChange(of: profiles.count) { _, _ in deduplicate() }
        .onChange(of: activePlans.count) { _, _ in deduplicate() }
    }

    /// Removes duplicate profiles and active plans introduced by CloudKit sync
    /// racing with local onboarding. Keeps the oldest profile (most history) and
    /// the newest active plan (most current training block).
    private func deduplicate() {
        // Profiles: oldest-first → drop everything after index 0
        if profiles.count > 1 {
            profiles.dropFirst().forEach { context.delete($0) }
            try? context.save()
        }
        // Active plans: newest-first → drop everything after index 0
        if activePlans.count > 1 {
            activePlans.dropFirst().forEach { context.delete($0) }
            try? context.save()
        }
    }
}
