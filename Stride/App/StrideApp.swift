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
/// Navigation is driven solely by whether a UserProfile exists in the store.
/// When CloudKit delivers a restored profile, `profiles.isEmpty` flips to false
/// and the app transitions to MainTabView automatically — no button tap required.
/// `welcomeBackPending` is still used by OnboardingView to choose between the
/// "Welcome Back / Checking iCloud" screen and the standard new-user flow.
struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container
    @Environment(AuthService.self) private var authService
    @Environment(AppSettings.self) private var appSettings

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

    // Tracks that we entered the app via a reinstall/restore flow and need to
    // re-register WorkoutKit plans once CloudKit delivers them.
    @State private var needsWorkoutKitSync = false

    var body: some View {
        Group {
            if profiles.isEmpty {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .task { deduplicate() }
        .onChange(of: profiles.count) { _, _ in deduplicate() }
        .onChange(of: activePlans.count) { oldCount, newCount in
            deduplicate()
            // CloudKit delivered the restored plan while in a reinstall flow — re-register
            // WorkoutKit scheduled workouts, which were wiped by the reinstall.
            if oldCount == 0, newCount > 0, needsWorkoutKitSync, let plan = activePlans.first {
                needsWorkoutKitSync = false
                Task {
                    try? await container.healthKitRepository.syncWorkoutPlans(
                        for: plan,
                        unitPreference: appSettings.unitPreference
                    )
                    if appSettings.morningReminderEnabled {
                        await container.notificationService.scheduleMorningReminders(for: plan)
                    }
                }
            }
        }
        // When the user already has a saved Apple ID but no local SwiftData records yet
        // (e.g. fresh install, reinstall), skip regular onboarding and go straight to the
        // CloudKit-restore screen so they don't accidentally create a duplicate profile.
        .task {
            if authService.isSignedIn && profiles.isEmpty {
                authService.welcomeBackPending = true
                needsWorkoutKitSync = true
            }
        }
        .onChange(of: authService.isSignedIn) { _, isSignedIn in
            if isSignedIn && profiles.isEmpty {
                authService.welcomeBackPending = true
                needsWorkoutKitSync = true
            }
        }
    }

    /// Removes duplicate profiles and active plans, and applies the one-time
    /// legacy-field migration that recovers enum values corrupted by the
    /// field-rename commit running without @Attribute(originalName:).
    private func deduplicate() {
        ProfileRestoreDeduplicator.applyLegacyFields(profiles, in: context)
        ProfileRestoreDeduplicator.applyLegacyFieldsToRelated(in: context)
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

    /// Copies old CloudKit field values from `*Legacy` shadow properties into the
    /// current `*Raw` fields whenever the current field still holds its default value.
    /// Nils out the legacy property afterwards so the migration is self-clearing.
    @MainActor
    static func applyLegacyFields(_ profiles: [UserProfile], in context: ModelContext) {
        var dirty = false
        for profile in profiles {
            if profile.genderRaw == Gender.preferNotToShare.rawValue,
               let legacy = profile.genderLegacy,
               legacy != Gender.preferNotToShare.rawValue {
                profile.genderRaw = legacy
                dirty = true
            }
            profile.genderLegacy = nil

            if profile.goalRaceRaw == RaceType.fiveK.rawValue,
               let legacy = profile.goalRaceLegacy,
               legacy != RaceType.fiveK.rawValue {
                profile.goalRaceRaw = legacy
                dirty = true
            }
            profile.goalRaceLegacy = nil

            if profile.fitnessLevelRaw == FitnessLevel.beginner.rawValue,
               let legacy = profile.fitnessLevelLegacy,
               legacy != FitnessLevel.beginner.rawValue {
                profile.fitnessLevelRaw = legacy
                dirty = true
            }
            profile.fitnessLevelLegacy = nil
        }
        if dirty { try? context.save() }
    }

    /// Applies the same legacy-field recovery to RunWorkout, ScheduledWorkout,
    /// TrainingPlan, TrainingWeek, and SavedRoute.
    @MainActor
    static func applyLegacyFieldsToRelated(in context: ModelContext) {
        var dirty = false

        if let runs = try? context.fetch(FetchDescriptor<RunWorkout>()) {
            for run in runs {
                if run.workoutTypeRaw == WorkoutType.easy.rawValue,
                   let legacy = run.workoutTypeLegacy,
                   legacy != WorkoutType.easy.rawValue {
                    run.workoutTypeRaw = legacy
                    dirty = true
                }
                run.workoutTypeLegacy = nil

                if run.workoutLocationRaw == WorkoutLocation.outdoor.rawValue,
                   let legacy = run.workoutLocationLegacy,
                   legacy != WorkoutLocation.outdoor.rawValue {
                    run.workoutLocationRaw = legacy
                    dirty = true
                }
                run.workoutLocationLegacy = nil
            }
        }

        if let scheduled = try? context.fetch(FetchDescriptor<ScheduledWorkout>()) {
            for workout in scheduled {
                if workout.workoutTypeRaw == WorkoutType.easy.rawValue,
                   let legacy = workout.workoutTypeLegacy,
                   legacy != WorkoutType.easy.rawValue {
                    workout.workoutTypeRaw = legacy
                    dirty = true
                }
                workout.workoutTypeLegacy = nil

                if workout.workoutLocationRaw == WorkoutLocation.outdoor.rawValue,
                   let legacy = workout.workoutLocationLegacy,
                   legacy != WorkoutLocation.outdoor.rawValue {
                    workout.workoutLocationRaw = legacy
                    dirty = true
                }
                workout.workoutLocationLegacy = nil
            }
        }

        if let plans = try? context.fetch(FetchDescriptor<TrainingPlan>()) {
            for plan in plans {
                if plan.targetRaceRaw == RaceType.fiveK.rawValue,
                   let legacy = plan.targetRaceLegacy,
                   legacy != RaceType.fiveK.rawValue {
                    plan.targetRaceRaw = legacy
                    dirty = true
                }
                plan.targetRaceLegacy = nil
            }
        }

        if let weeks = try? context.fetch(FetchDescriptor<TrainingWeek>()) {
            for week in weeks {
                if week.phaseRaw == TrainingPhase.base.rawValue,
                   let legacy = week.phaseLegacy,
                   legacy != TrainingPhase.base.rawValue {
                    week.phaseRaw = legacy
                    dirty = true
                }
                week.phaseLegacy = nil
            }
        }

        if let routes = try? context.fetch(FetchDescriptor<SavedRoute>()) {
            for route in routes {
                if route.routeTypeRaw == RouteType.loop.rawValue,
                   let legacy = route.routeTypeLegacy,
                   legacy != RouteType.loop.rawValue {
                    route.routeTypeRaw = legacy
                    dirty = true
                }
                route.routeTypeLegacy = nil
            }
        }

        if dirty { try? context.save() }
    }

    @MainActor
    static func deduplicate(_ profiles: [UserProfile], in context: ModelContext) throws {
        guard profiles.count > 1, let winner = preferredProfile(from: profiles) else { return }

        for profile in profiles where profile.persistentModelID != winner.persistentModelID {
            mergeRestoreFields(from: profile, into: winner)
        }

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

    /// During CloudKit restore, we can briefly end up with both:
    /// - a newly created local onboarding profile (often blank/default fields), and
    /// - a restored profile containing real personal preferences.
    ///
    /// Keep newest-profile semantics overall, but copy user-facing fields that
    /// are still blank/default on the winner before deleting the older profile.
    private static func mergeRestoreFields(from source: UserProfile, into target: UserProfile) {
        if target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            target.name = source.name
        }

        if target.gender == .preferNotToShare,
           source.gender != .preferNotToShare {
            target.gender = source.gender
        }

        if !source.preferredRunDayIndices.isEmpty {
            target.preferredRunDayIndices = source.preferredRunDayIndices
            target.weeklyRunDays = source.weeklyRunDays
        }

        target.updatedAt = max(target.updatedAt, source.updatedAt)
    }
}
