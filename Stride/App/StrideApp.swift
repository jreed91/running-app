import SwiftUI
import SwiftData

@main
struct StrideApp: App {

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
                    PulseIntegrationService.activateIfNeeded()
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

    // Sorted newest-first to bias the UI toward the most recently updated profile
    // while launch-time dedup resolves any duplicates delivered by CloudKit.
    @Query(sort: \UserProfile.updatedAt, order: .reverse)
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
        // When the user already has a saved Apple ID but no local SwiftData records yet
        // (e.g. fresh install, reinstall), skip regular onboarding and go straight to the
        // CloudKit-restore screen so they don't accidentally create a duplicate profile.
        .task {
            if authService.isSignedIn && profiles.isEmpty {
                authService.welcomeBackPending = true
            }
        }
        .onChange(of: authService.isSignedIn) { _, isSignedIn in
            if isSignedIn && profiles.isEmpty {
                authService.welcomeBackPending = true
            }
        }
    }

    /// Removes duplicate profiles and active plans introduced by CloudKit sync
    /// racing with local onboarding. Keeps the most recently updated profile and
    /// the newest active plan.
    private func deduplicate() {
        try? ProfileRestoreDeduplicator.deduplicate(profiles, in: context)
        // Active plans: newest-first → drop everything after index 0
        if activePlans.count > 1 {
            activePlans.dropFirst().forEach { context.delete($0) }
            try? context.save()
        }
    }
}

enum ProfileRestoreDeduplicator {
    static func preferredProfile(from profiles: [UserProfile]) -> UserProfile? {
        profiles.max(by: isLessPreferred)
    }

    @MainActor
    static func deduplicate(_ profiles: [UserProfile], in context: ModelContext) throws {
        guard profiles.count > 1, let winner = preferredProfile(from: profiles) else { return }

        for profile in profiles where profile.persistentModelID != winner.persistentModelID {
            context.delete(profile)
        }

        try context.save()
    }

    private static func isLessPreferred(_ lhs: UserProfile, _ rhs: UserProfile) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }

        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }
}
