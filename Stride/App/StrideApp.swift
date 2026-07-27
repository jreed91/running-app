import SwiftUI
import SwiftData
import CoreLocation
import UserNotifications
import HealthKit

@main
struct StrideApp: App {

    @UIApplicationDelegateAdaptor(StrideAppDelegate.self) private var appDelegate
    @State private var container: AppContainer
    @State private var appSettings: AppSettings
    @State private var authService: AuthService

    init() {
        // Must run before anything below: AppContainer and AppSettings both read
        // UserDefaults / iCloud KVS during their own initialization, so clearing
        // UI-test state from a later hook would be too late to matter.
        UITestingSupport.prepareIfNeeded()

        // `isHostingUnitTests` as well as `isEnabled`: a unit-test run launches this app
        // as its host, and the real on-disk/CloudKit store it used to open outlived every
        // individual test in the same coordinator.
        let appContainer = AppContainer(
            inMemory: UITestingSupport.isEnabled || UITestingSupport.isHostingUnitTests
        )
        // Before the first view reads the store, so a seeded screen never renders its
        // empty state first and animates the data in. No-op without --seed-demo-data.
        DemoDataSeed.populateIfNeeded(appContainer.modelContainer)
        _container = State(initialValue: appContainer)
        _appSettings = State(initialValue: AppSettings())
        _authService = State(initialValue: AuthService())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(container)
                .environment(appSettings)
                .environment(authService)
                .modelContainer(container.modelContainer)
                .task {
                    PulseIntegrationService.activateIfNeeded()
                    // Also skipped when hosting unit tests: the HealthKit observer and
                    // the startup sync were running underneath every unit-test run,
                    // mutating the store the tests were asserting on.
                    guard !UITestingSupport.isEnabled,
                          !UITestingSupport.isHostingUnitTests else { return }
                    // An app killed mid-run leaves its Live Activity on the Lock Screen
                    // with nothing behind it to update or end (U5b). The run went with the
                    // process, so the card comes down here rather than going stale.
                    container.runActivityController.endActivitiesFromPreviousLaunches()
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
                        UserDefaults.standard.removeObject(
                            forKey: NotificationService.pendingReviewWorkoutIDKey
                        )
                    }
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    /// Handles `stride://` links: the run's Live Activity (U5b/U7) and the Home Screen /
    /// Lock Screen widgets (B1), each of which should land on the surface it was showing
    /// rather than merely foregrounding the app onto whatever was open last.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == RunActivityDeepLink.scheme, let host = url.host else { return }

        switch host {
        case RunActivityDeepLink.activeRunHost:
            // Guarded on a run actually recording, because a Live Activity can be tapped
            // in the moment between the run finishing and the card being dismissed — and
            // reopening the HUD onto a finished tracker would show a run that has already
            // been saved.
            guard container.workoutTrackerService.isRecording else { return }
            container.activeRunPresentation.reopen()
        case StrideWidgetDeepLink.planHost:
            container.appNavigation.select(.plan)
        case StrideWidgetDeepLink.progressHost:
            container.appNavigation.select(.progress)
        case StrideWidgetDeepLink.homeHost:
            container.appNavigation.select(.home)
        default:
            break
        }
    }
}

private struct PendingReviewSheet: ViewModifier {
    // `AppContainer` is `@Observable`, so reading `pendingReviewWorkout` in `body`
    // is what subscribes this modifier to it — no property wrapper needed (D4).
    let container: AppContainer
    let appSettings: AppSettings
    let authService: AuthService

    func body(content: Content) -> some View {
        content.sheet(isPresented: isPresented) {
            if let workout = container.pendingReviewWorkout {
                NavigationStack {
                    RunSummaryView(workout: workout)
                }
                .environment(container)
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
    @Environment(AppContainer.self) private var container
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

    /// Store-recovery notice taken from the container once and cleared there, so the
    /// alert is driven by local state and can't reappear if the root is rebuilt.
    ///
    /// It lives here rather than on `MainTabView` because the case it exists for —
    /// a store that could not be migrated and was recreated empty — leaves no
    /// `UserProfile`, so the app shows `OnboardingView` and `MainTabView` is never
    /// mounted. Presented at the root, it reaches the user in both branches (N5).
    @State private var recoveryNotice: AppContainer.StoreRecoveryNotice?

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
        .task {
            guard let notice = container.storeRecoveryNotice else { return }
            container.storeRecoveryNotice = nil
            recoveryNotice = notice
        }
        // `alert(_:item:)` (iOS 27) drives presentation straight off the optional, so
        // the hand-rolled `Binding(get:set:)` bridge and the separate `presenting:`
        // argument both go away — and the action no longer has to nil the state by
        // hand, since dismissing is what clears the binding.
        .alert(
            recoveryNotice?.title ?? "",
            item: $recoveryNotice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .task(id: activePlans.first?.id) {
            deduplicate()
            await reconcileActivePlanIntegrations()
            // A new plan replaces every widget's "next workout" and its race countdown
            // at once, so it is worth a refresh of its own rather than waiting for the
            // app to be backgrounded (B1).
            WidgetRefreshService.refresh(context: context, appSettings: appSettings)
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
        // The widgets' catch-all (B1). `.background` is the one that matters — it is the
        // last chance to publish whatever the runner just did before they go and look at
        // the Home Screen — and `.active` covers a snapshot that went stale while the app
        // was away, most often because the date rolled over. Neither costs a WidgetKit
        // reload unless the snapshot actually moved; see `WidgetRefreshService`.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active || phase == .background else { return }
            WidgetRefreshService.refresh(context: context, appSettings: appSettings)
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
        // `activePlans` is sorted newest-first, so index 0 is the plan to keep.
        ProfileRestoreDeduplicator.retireDuplicateActivePlans(activePlans, in: context)
    }

    @MainActor
    private func reconcileActivePlanIntegrations() async {
        guard !UITestingSupport.isEnabled,
              !UITestingSupport.isHostingUnitTests,
              let plan = activePlans.first else { return }

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
            context.saveOrLog("the WorkoutKit plan ids")
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
        if dirty { context.saveOrLog("the profile enum migration") }
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

        if dirty { context.saveOrLog("the route enum migration") }
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

        if dirty { context.saveOrLog("restored run-to-plan links") }
    }

    /// Restores the single-active-plan invariant by **deactivating** every plan after
    /// the first, which the caller supplies newest-first.
    ///
    /// These duplicates are not corrupt data: two active plans is what a CloudKit
    /// multi-device race produces, when a plan created on one device arrives while
    /// another device's plan is still active. Deleting the loser — as this did — threw
    /// away a real training block, its weeks, and every completed workout in them,
    /// on a path that runs at every launch (N2). Deactivating keeps the block in
    /// Plan History and is just as effective at making `fetchActivePlan` deterministic.
    ///
    /// - Returns: how many plans were retired.
    @MainActor
    @discardableResult
    static func retireDuplicateActivePlans(
        _ activePlansNewestFirst: [TrainingPlan],
        in context: ModelContext
    ) -> Int {
        guard activePlansNewestFirst.count > 1 else { return 0 }
        let toRetire = activePlansNewestFirst.dropFirst().filter(\.isActive)
        guard !toRetire.isEmpty else { return 0 }
        toRetire.forEach { $0.isActive = false }
        context.saveOrLog("retired duplicate active plans")
        return toRetire.count
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
