import SwiftUI
import SwiftData
import CoreLocation
import UserNotifications
import HealthKit

@main
struct StrideApp: App {

    @UIApplicationDelegateAdaptor(StrideAppDelegate.self) private var appDelegate
    @StateObject private var container = AppContainer(inMemory: UITestingSupport.isEnabled)
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
                    guard !UITestingSupport.isEnabled else { return }
                    await container.workoutSyncService.startObserving()
                    await authService.checkCredentialState()
                    container.checkForPendingReviewWorkout()
                    // Index recent runs so Siri / Spotlight / Apple Intelligence can find
                    // and reference them by natural language.
                    await RunSpotlightIndexer.indexRecentRuns(
                        in: container.modelContainer,
                        unit: appSettings.unitPreference
                    )
                }
                .modifier(PendingReviewSheet(
                    container: container,
                    appSettings: appSettings,
                    authService: authService
                ))
                .onChange(of: container.pendingReviewWorkout) { _, newValue in
                    if newValue == nil {
                        UserDefaults.standard.removeObject(forKey: "pendingReviewWorkoutID")
                    }
                }
        }
    }
}

private struct PendingReviewSheet: ViewModifier {
    @ObservedObject var container: AppContainer
    let appSettings: AppSettings
    let authService: AuthService

    func body(content: Content) -> some View {
        content.sheet(isPresented: isPresented) {
            if let workout = container.pendingReviewWorkout {
                NavigationStack {
                    RunSummaryView(workout: workout)
                }
                .environment(\.appContainer, container)
                .environment(appSettings)
                .environment(authService)
                .modelContainer(container.modelContainer)
            }
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { container.pendingReviewWorkout != nil },
            set: { isPresented in
                if !isPresented {
                    container.pendingReviewWorkout = nil
                }
            }
        )
    }
}

@MainActor
final class StrideAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationService.shared.installAsDelegate()
        return true
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
    @State private var hasRunRestorePermissionCheck = false
    @State private var isRunningRestorePermissionCheck = false

    @Environment(\.scenePhase) private var scenePhase

    private let restoreLocationManager = CLLocationManager()

    var body: some View {
        Group {
            if profiles.isEmpty {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .task(id: activePlans.first?.id) {
            deduplicate()
            await reconcileActivePlanIntegrations()
        }
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

            if newCount > 0 {
                Task { await requestMissingPermissionsAfterRestoreIfNeeded() }
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
        .onChange(of: profiles.count) { _, newCount in
            if newCount > 0 {
                Task { await requestMissingPermissionsAfterRestoreIfNeeded() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active,
                  appSettings.morningReminderEnabled,
                  let plan = activePlans.first else { return }
            Task {
                await container.notificationService.scheduleMorningReminders(for: plan)
            }
        }
    }

    /// Removes duplicate profiles and active plans, and applies the one-time
    /// legacy-field migration that recovers enum values corrupted by the
    /// field-rename commit running without @Attribute(originalName:).
    private func deduplicate() {
        ProfileRestoreDeduplicator.applyLegacyFields(profiles, in: context)
        ProfileRestoreDeduplicator.applyLegacyFieldsToRelated(in: context)
        ProfileRestoreDeduplicator.repairRelationships(in: context)
        try? ProfileRestoreDeduplicator.deduplicate(profiles, in: context)
        // Active plans: newest-first → drop everything after index 0
        if activePlans.count > 1 {
            activePlans.dropFirst().forEach { context.delete($0) }
            try? context.save()
        }
    }

    @MainActor
    private func reconcileActivePlanIntegrations() async {
        guard !UITestingSupport.isEnabled, let plan = activePlans.first else { return }

        if appSettings.morningReminderEnabled {
            await container.notificationService.scheduleMorningReminders(for: plan)
        } else {
            await container.notificationService.cancelAllMorningReminders()
        }

        do {
            try await container.healthKitRepository.syncWorkoutPlans(
                for: plan,
                unitPreference: appSettings.unitPreference
            )
            try? context.save()
            AppLogger.log("Active plan synced to WorkoutKit.", label: "WorkoutKit", level: .info)
        } catch {
            AppLogger.log(
                "Active plan WorkoutKit sync failed: \(error.localizedDescription)",
                label: "WorkoutKit",
                level: .error
            )
        }
    }

    private func requestMissingPermissionsAfterRestoreIfNeeded() async {
        guard needsWorkoutKitSync, !profiles.isEmpty else { return }
        guard !hasRunRestorePermissionCheck, !isRunningRestorePermissionCheck else { return }

        isRunningRestorePermissionCheck = true
        defer {
            isRunningRestorePermissionCheck = false
            hasRunRestorePermissionCheck = true
        }

        let locationStatus = restoreLocationManager.authorizationStatus
        if locationStatus != .authorizedAlways, locationStatus != .authorizedWhenInUse {
            restoreLocationManager.requestWhenInUseAuthorization()
            try? await Task.sleep(nanoseconds: 1_600_000_000)
        }

        if HKHealthStore.isHealthDataAvailable() {
            // HealthKit deliberately does not expose *read* authorization status, so
            // `authorizationStatus(for:)` reports only share/write permission and misfires
            // in both directions when used to gate imports (M17). `requestAuthorization()`
            // is idempotent — it never re-prompts once the user has decided — and
            // `startObserving()` guards against duplicate observer registration, so we
            // simply ensure both have run rather than branching on an unreliable signal.
            try? await container.healthKitRepository.requestAuthorization()
            await container.workoutSyncService.startObserving()
        }

        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        let hasNotificationAuth = notificationSettings.authorizationStatus == .authorized ||
            notificationSettings.authorizationStatus == .provisional
        if !hasNotificationAuth {
            try? await NotificationService.shared.requestAuthorization()
        }
        if appSettings.morningReminderEnabled, let plan = activePlans.first {
            await container.notificationService.scheduleMorningReminders(for: plan)
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

    /// Re-stitches RunWorkout ↔ ScheduledWorkout relationships using the primitive ID backup
    /// fields after a CloudKit restore. CloudKit delivers records asynchronously and may
    /// resolve relationship references only after both sides have arrived; the stored UUIDs
    /// let us repair any gaps without waiting for a second sync cycle.
    @MainActor
    static func repairRelationships(in context: ModelContext) {
        guard let runs = try? context.fetch(FetchDescriptor<RunWorkout>()),
              let scheduled = try? context.fetch(FetchDescriptor<ScheduledWorkout>()) else { return }

        let scheduledByID = Dictionary(uniqueKeysWithValues: scheduled.map { ($0.id, $0) })
        let runsByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        var dirty = false

        for run in runs where run.scheduledWorkout == nil {
            guard let linkedID = run.linkedScheduledWorkoutID,
                  let match = scheduledByID[linkedID] else { continue }
            run.scheduledWorkout = match
            if match.completedWorkout == nil {
                match.completedWorkout = run
                match.isCompleted = true
            }
            dirty = true
        }

        for sw in scheduled where sw.completedWorkout == nil {
            guard let linkedID = sw.linkedRunWorkoutID,
                  let match = runsByID[linkedID] else { continue }
            sw.completedWorkout = match
            sw.isCompleted = true
            if match.scheduledWorkout == nil {
                match.scheduledWorkout = sw
            }
            dirty = true
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
