import Foundation
import CloudKit
import CoreData
import SwiftData

// MARK: - AppContainer

/// Central dependency-injection container.
///
/// Initialised once at app launch and injected via SwiftUI's `Environment`.
/// Services are singletons within the container lifetime.
@MainActor
final class AppContainer: ObservableObject {

    enum PersistenceMode: Equatable {
        case cloudKit
        case inMemory
        case localOnly
        case localFallback
        case recreatedLocalFallback
        case emergencyInMemory
    }

    /// A store-open problem worth interrupting the user for.
    ///
    /// `.localFallback` is deliberately absent: the file is intact, the data is all
    /// there, and it re-syncs when CloudKit recovers, so there is nothing for the
    /// user to do. The two cases here are the ones where they could otherwise be
    /// left staring at an empty app with no idea why.
    enum StoreRecoveryNotice: Identifiable, Equatable {
        /// The old store could not be migrated and was set aside under this filename.
        case storeMovedAside(backupName: String?)
        /// Nothing could be opened on disk; this launch is running from memory.
        case runningInMemory

        init?(mode: PersistenceMode, movedAsideStoreName: String?) {
            switch mode {
            case .recreatedLocalFallback:
                self = .storeMovedAside(backupName: movedAsideStoreName)
            case .emergencyInMemory:
                self = .runningInMemory
            case .cloudKit, .inMemory, .localOnly, .localFallback:
                return nil
            }
        }

        var id: String {
            switch self {
            case .storeMovedAside: "storeMovedAside"
            case .runningInMemory: "runningInMemory"
            }
        }

        var title: String {
            switch self {
            case .storeMovedAside: "Your training data couldn't be opened"
            case .runningInMemory: "Running without saved data"
            }
        }

        var message: String {
            switch self {
            case .storeMovedAside(let backupName):
                let location = backupName.map { " It's kept on this device as \($0)." } ?? ""
                return """
                Stride started with a fresh, empty database because your existing one \
                couldn't be read by this version.\(location) Nothing was deleted — if you \
                had iCloud Sync on, your data will come back down from iCloud shortly.
                """
            case .runningInMemory:
                return """
                Stride couldn't open its database this time, so anything you record now \
                will not be saved. Your existing data has been left untouched. Please \
                restart the app; if this keeps happening, restart your device.
                """
            }
        }
    }

    // MARK: SwiftData

    let modelContainer: ModelContainer
    let persistenceMode: PersistenceMode

    /// Set when the persistent store could not be opened normally, so the UI can tell
    /// the user what happened instead of silently running on a different store (C3).
    /// Cleared once acknowledged.
    @Published var storeRecoveryNotice: StoreRecoveryNotice?

    /// The iCloud-sync preference the store was actually opened with. Settings
    /// compares the live preference against this to decide whether a restart is
    /// genuinely still pending, so the "restart to apply" note clears itself when
    /// the user toggles back rather than latching for the rest of the session.
    let syncPreferenceAtLaunch: Bool

    // MARK: Repositories

    let workoutRepository: WorkoutRepositoryProtocol
    let planRepository: PlanRepositoryProtocol
    let healthKitRepository: HealthKitRepositoryProtocol
    let routeRepository: RouteRepositoryProtocol

    // MARK: Services

    let trainingPlanService: TrainingPlanService
    let workoutTrackerService: WorkoutTrackerService
    let notificationService: NotificationService
    let workoutAnalyticsService: WorkoutAnalyticsService
    let routeGeniusService: RouteGeniusService
    let workoutSyncService: WorkoutSyncService
    let weatherService: WeatherService
    let aiCoachService: AICoachService

    // MARK: Workout Review

    /// Set when a workout is synced from HealthKit (background or foreground) or when the user
    /// taps a "Run Synced" notification. Presenting a RunSummaryView sheet on this value lets
    /// the user review their workout and confirms the auto-link to today's planned workout.
    @Published var pendingReviewWorkout: RunWorkout?

    // MARK: Init

    init(
        inMemory: Bool = false,
        syncEnabledOverride: Bool? = nil,
        forceCloudKit: Bool? = nil,
        storeURLOverride: URL? = nil,
        modelContainerFactory: (Schema, [ModelConfiguration]) throws -> ModelContainer = {
            try ModelContainer(for: $0, configurations: $1)
        }
    ) {
        PulseIntegrationService.activateIfNeeded()

        let schema = StrideSchema.make()
        // Read the preference set during onboarding / Settings.
        // UserDefaults is checked directly here because AppSettings doesn't
        // exist yet at the point AppContainer is initialized.
        let syncEnabled = syncEnabledOverride ?? AppSettings.syncedICloudEnabled()

        // Explicit container ID so every code path targets the same CloudKit store.
        let ckContainerID = "iCloud.com.running.stride"

        // Shared on-disk URL keeps the CloudKit store and any local-fallback store
        // pointing at the same SQLite file. When CloudKit recovers, NSPersistentCloudKitContainer
        // picks up records that were written during an outage and pushes them automatically.
        let storeURL = storeURLOverride ?? StrideSchema.storeURL

        let cloudKitEnabled = forceCloudKit ?? Self.shouldUseCloudKit(syncEnabled: syncEnabled, inMemory: inMemory)

        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if cloudKitEnabled {
            config = ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .private(ckContainerID)
            )
        } else {
            config = ModelConfiguration(schema: schema, url: storeURL)
        }

        // Fallback uses the SAME on-disk URL — data is never orphaned in a separate store.
        let localConfig = ModelConfiguration(schema: schema, url: storeURL)
        let container: ModelContainer
        let persistenceMode: PersistenceMode
        var movedAsideStoreName: String? = nil
        do {
            container = try modelContainerFactory(schema, [config])
            if inMemory {
                persistenceMode = .inMemory
            } else {
                persistenceMode = cloudKitEnabled ? .cloudKit : .localOnly
            }
            AppLogger.log("Store opened OK (syncEnabled=\(syncEnabled), cloudKitEnabled=\(cloudKitEnabled))", label: "AppContainer", level: .info)
        } catch let primaryError {
            AppLogger.log("CloudKit store failed (\(primaryError)); falling back to local-only at same URL", label: "AppContainer", level: .error)
            guard !inMemory else {
                fatalError("[AppContainer v5] In-memory ModelContainer failed: \(primaryError)")
            }

            // Tier 1 — same file, CloudKit disabled. Records written here will be
            // exported to CloudKit automatically once the container succeeds on a later launch.
            // Only attempted when the primary config actually used CloudKit: with CloudKit
            // off, the primary config IS `localConfig`, so retrying the identical
            // configuration can't succeed and would just mask a deterministic failure.
            let tier1Container: ModelContainer? = cloudKitEnabled
                ? try? modelContainerFactory(schema, [localConfig])
                : nil
            if let c = tier1Container {
                container = c
                persistenceMode = .localFallback
                AppLogger.log("Tier1: local-only store OK (data will sync when CloudKit recovers)", label: "AppContainer", level: .notice)
            } else if Self.isLikelyMigrationFailure(primaryError) {
                // Tier 2 — move the on-disk store aside and recreate local-only.
                //
                // Only reached for errors that identify the file as unreadable by this
                // build (schema/migration failures). A transient problem — the device
                // locked with file protection on, a disk that is momentarily full, a
                // CloudKit hiccup — must never reach here: renaming the store on a
                // failure that would have cleared itself next launch is how a user's
                // whole history "disappears". Never delete either, so even a genuine
                // migration bug leaves the data recoverable.
                let backupTag = ".broken-\(Int(Date().timeIntervalSince1970))"
                for suffix in ["", "-shm", "-wal"] {
                    let source = URL(fileURLWithPath: storeURL.path + suffix)
                    let backup = URL(fileURLWithPath: storeURL.path + backupTag + suffix)
                    try? FileManager.default.moveItem(at: source, to: backup)
                }
                AppLogger.log(
                    "Tier2: migration failure — moved store aside to \(storeURL.lastPathComponent + backupTag) and recreating",
                    label: "AppContainer",
                    level: .warning
                )

                if let c = try? modelContainerFactory(schema, [localConfig]) {
                    container = c
                    persistenceMode = .recreatedLocalFallback
                    movedAsideStoreName = storeURL.lastPathComponent + backupTag
                    AppLogger.log("Tier2: fresh local store created OK", label: "AppContainer", level: .notice)
                } else {
                    (container, persistenceMode) = Self.openEmergencyInMemoryStore(
                        schema: schema,
                        factory: modelContainerFactory
                    )
                }
            } else {
                // Tier 3 — the failure looks transient, so the on-disk store is left
                // exactly as it is and this launch runs from memory. Nothing persists
                // this session, but the next launch gets another shot at the real file.
                AppLogger.log(
                    "Store open failed with a non-migration error — leaving the file intact and running in-memory for this launch",
                    label: "AppContainer",
                    level: .critical
                )
                (container, persistenceMode) = Self.openEmergencyInMemoryStore(
                    schema: schema,
                    factory: modelContainerFactory
                )
            }
        }

        self.modelContainer = container
        self.persistenceMode = persistenceMode
        self.syncPreferenceAtLaunch = syncEnabled
        self.storeRecoveryNotice = StoreRecoveryNotice(
            mode: persistenceMode,
            movedAsideStoreName: movedAsideStoreName
        )

        let context = container.mainContext
        self.workoutRepository = WorkoutRepository(context: context)
        self.planRepository = PlanRepository(context: context)
        let hkRepository = HealthKitRepository()
        self.healthKitRepository = hkRepository
        self.routeRepository = RouteRepository(context: context)

        self.trainingPlanService = TrainingPlanService()
        self.workoutTrackerService = WorkoutTrackerService()
        let notifications = NotificationService.shared
        self.notificationService = notifications
        self.workoutAnalyticsService = WorkoutAnalyticsService()
        self.routeGeniusService = RouteGeniusService(
            session: PulseIntegrationService.makeInstrumentedURLSession()
        )
        let weather = WeatherService()
        self.weatherService = weather
        self.aiCoachService = AICoachService()
        self.workoutSyncService = WorkoutSyncService(
            healthKitRepository: hkRepository,
            notificationService: notifications,
            weatherService: weather,
            context: context
        )

        self.configureCloudKitDiagnostics(cloudKitEnabled: cloudKitEnabled)

        // Wire background-sync callback: surface the review sheet immediately if the app is
        // in the foreground when the sync fires. UserDefaults is written by WorkoutSyncService
        // so a cold launch also surfaces the workout via checkForPendingReviewWorkout().
        workoutSyncService.onWorkoutsSynced = { [weak self] workouts in
            guard let self, let first = workouts.first else { return }
            self.pendingReviewWorkout = first
        }

        // Wire notification-tap callback only for the real app container. The EnvironmentKey
        // default creates an in-memory fallback container, and letting that container own this
        // singleton callback means notification taps update a hidden container instead of the
        // SwiftUI root container.
        if !inMemory {
            notifications.onSyncedRunTapped = { [weak self] idString in
                self?.surfacePendingReviewWorkout(idString: idString)
            }
        }
    }

    // MARK: - Store failure classification

    /// Cocoa error codes that mean "this file cannot be read by this build", as
    /// opposed to "this failed right now and might not next time".
    ///
    /// Core Data groups migration failures in 134100–134199 (incompatible version
    /// hash, missing source/mapping model, inferred-mapping failures, entity-policy
    /// failures). 134020 is `NSPersistentStoreIncompatibleSchemaError`, which SwiftData
    /// raises when the declared schema does not match what is on disk. 259 is
    /// `NSFileReadCorruptFileError`: a corrupt store will not un-corrupt itself, so
    /// it belongs here too, and it is what a truncated or non-database file reports.
    private static let unreadableStoreErrorCodes: Set<Int> = Set(134_100...134_199).union([134_020, 259])

    /// Whether a store-open failure means the file itself is incompatible, as opposed
    /// to something that could clear up on its own.
    ///
    /// Only a definite match moves the user's store aside — an unrecognised error is
    /// treated as transient, which is the safe direction to be wrong in: a needless
    /// in-memory launch is annoying, a needlessly renamed database looks like data loss.
    static func isLikelyMigrationFailure(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == NSCocoaErrorDomain, unreadableStoreErrorCodes.contains(nsError.code) {
                return true
            }
            // Core Data reports batch failures with the real causes in `NSDetailedErrors`.
            if let detailed = nsError.userInfo[NSDetailedErrorsKey] as? [NSError],
               detailed.contains(where: { $0.domain == NSCocoaErrorDomain && unreadableStoreErrorCodes.contains($0.code) }) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// Last-resort in-memory store. Traps only if even that fails, which means
    /// SwiftData itself is unusable on the device and there is nothing left to try.
    private static func openEmergencyInMemoryStore(
        schema: Schema,
        factory: (Schema, [ModelConfiguration]) throws -> ModelContainer
    ) -> (ModelContainer, PersistenceMode) {
        AppLogger.log("Falling back to an in-memory store — data will not persist this launch", label: "AppContainer", level: .critical)
        let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return (try factory(schema, [memConfig]), .emergencyInMemory)
        } catch {
            fatalError("[AppContainer] In-memory ModelContainer failed — SwiftData is broken on this device: \(error)")
        }
    }

    private static func shouldUseCloudKit(syncEnabled: Bool, inMemory: Bool) -> Bool {
        guard syncEnabled, !inMemory else { return false }

        #if targetEnvironment(simulator)
        AppLogger.log("CloudKit disabled in simulator; using local SwiftData store", label: "AppContainer", level: .debug)
        return false
        #else
        return true
        #endif
    }

    // MARK: - Weather

    /// Fetches weather for the given coordinate and attaches it to the workout, then saves.
    /// Silently no-ops if WeatherKit is unavailable or the workout has no coordinate.
    ///
    /// The body lives on `WeatherService` so the importer's copy and this one can't
    /// drift (N27).
    func attachWeather(to workout: RunWorkout, coordinate: Coordinate) async {
        await weatherService.attach(
            to: workout,
            coordinate: coordinate,
            context: modelContainer.mainContext
        )
    }

    // MARK: - Workout Review

    /// Checks UserDefaults for a workout that was synced while the app was not in the foreground
    /// and surfaces it for review. Called at launch so cold-opens also trigger the review sheet.
    func checkForPendingReviewWorkout() {
        // Drop review snapshots (full run copies in UserDefaults) for runs that
        // have since imported into the store, so they don't accumulate (S3).
        let storedRunIDs = Set(
            ((try? modelContainer.mainContext.fetch(FetchDescriptor<RunWorkout>())) ?? []).map(\.id)
        )
        NotificationService.pruneReviewSnapshots(storedRunIDs: storedRunIDs)

        guard
            let idString = UserDefaults.standard.string(forKey: NotificationService.pendingReviewWorkoutIDKey),
            pendingReviewWorkout == nil
        else { return }
        surfacePendingReviewWorkout(idString: idString)
    }

    private func surfacePendingReviewWorkout(idString: String) {
        guard let uuid = UUID(uuidString: idString) else {
            AppLogger.log("Ignored pending review with invalid UUID \(idString)", label: "Notifications", level: .warning)
            return
        }
        let context = modelContainer.mainContext
        let all = (try? context.fetch(FetchDescriptor<RunWorkout>())) ?? []
        let workout: RunWorkout
        if let storedWorkout = all.first(where: { $0.id == uuid }) {
            workout = storedWorkout
        } else if let snapshotWorkout = notificationService.workoutFromReviewSnapshot(idString: idString) {
            // Resurrection guard (M6): the snapshot is a full copy of a synced run. Before
            // re-inserting it, make sure the run wasn't deliberately deleted (tombstoned) and
            // isn't already present under a different local id but the same HealthKit source.
            let hkID = snapshotWorkout.healthKitWorkoutID
            let tombstoned = (try? context.fetch(FetchDescriptor<DeletedWorkout>())) ?? []
            let isTombstoned = hkID.map { id in tombstoned.contains { $0.healthKitWorkoutID == id } } ?? false
            let existingSameSource = hkID.flatMap { id in all.first { $0.healthKitWorkoutID == id } }

            if isTombstoned {
                AppLogger.log("Skipped resurrecting tombstoned review snapshot id=\(idString)", label: "Notifications", level: .warning)
                clearPendingReview(idString: idString)
                return
            }
            if let existingSameSource {
                // Already imported under a new id — surface the real row instead of a duplicate.
                pendingReviewWorkout = existingSameSource
                clearPendingReview(idString: idString)
                return
            }

            context.insert(snapshotWorkout)
            try? context.save()
            workout = snapshotWorkout
        } else {
            AppLogger.log("Could not find workout for pending review id=\(idString); fetched \(all.count) workouts", label: "Notifications", level: .warning)
            return
        }
        pendingReviewWorkout = workout
        clearPendingReview(idString: idString)
    }

    /// Clears the persisted pending-review pointer and its snapshot once the run has been
    /// surfaced (or intentionally skipped), so it can't re-trigger on the next launch.
    private func clearPendingReview(idString: String) {
        UserDefaults.standard.removeObject(forKey: NotificationService.pendingReviewWorkoutIDKey)
        notificationService.removeReviewSnapshot(idString: idString)
    }

    // MARK: - Route Genius

    /// Creates a fresh ``RouteGeniusViewModel`` wired to the container's service and repository.
    func makeRouteGeniusViewModel(appSettings: AppSettings) -> RouteGeniusViewModel {
        RouteGeniusViewModel(
            service: routeGeniusService,
            repository: routeRepository,
            appSettings: appSettings
        )
    }

    // MARK: - Workout adaptation

    /// Returns an AI-adapted ``ScheduledWorkout`` based on the runner's recent history.
    /// If AI is unavailable or returns an invalid structured response, the original
    /// workout is returned unchanged.
    func adaptedWorkout(
        scheduled: ScheduledWorkout,
        history: [RunWorkout],
        profile: UserProfile,
        provider: AIProvider,
        unitPreference: UnitPreference = .metric
    ) async -> ScheduledWorkout {
        await aiCoachService.adaptScheduledWorkoutWithProvider(
            scheduled: scheduled,
            recentHistory: history,
            profile: profile,
            provider: provider,
            unitPreference: unitPreference
        ) ?? scheduled
    }

    /// Returns AI-adapted workouts for a plan batch using a single provider request.
    func adaptedWorkouts(
        scheduled workouts: [ScheduledWorkout],
        history: [RunWorkout],
        profile: UserProfile,
        provider: AIProvider,
        unitPreference: UnitPreference = .metric,
        onChunk: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> [UUID: ScheduledWorkout] {
        await aiCoachService.adaptScheduledWorkoutsWithProvider(
            scheduled: workouts,
            recentHistory: history,
            profile: profile,
            provider: provider,
            unitPreference: unitPreference,
            onChunk: onChunk
        )
    }

    // MARK: - Continuous plan refresh

    /// Re-derives training paces from recent history and updates all future uncompleted
    /// workouts in the plan. Call this after the user completes any run so workout
    /// targets stay aligned with their current VDOT for any number of weekly run days.
    func refreshPlanAfterWorkout(
        plan: TrainingPlan,
        history: [RunWorkout],
        profile: UserProfile,
        unitPreference: UnitPreference = .metric
    ) {
        trainingPlanService.refreshPaces(
            plan: plan,
            history: history,
            profile: profile,
            unitPreference: unitPreference
        )
    }

    // MARK: - Schedule management

    /// Redistributes uncompleted future workouts to match the given run day indices.
    /// Excess workouts that no longer fit the new schedule are deleted from the context.
    func rescheduleWorkouts(
        in plan: TrainingPlan,
        newDayIndices: [Int],
        profile: UserProfile?,
        context: ModelContext
    ) {
        let toDelete = trainingPlanService.applyNewRunDays(to: plan, newDayIndices: newDayIndices, profile: profile)
        for workout in toDelete {
            context.delete(workout)
        }
    }

    // MARK: - Missed workout recovery

    /// Shifts all future uncompleted training workouts forward by `days` calendar days.
    /// Extends `plan.endDate` if any shifted workout falls beyond it.
    /// Race workouts are excluded when the plan has a fixed raceDate.
    ///
    /// Strength and cross-training move with the runs. Holding them still while the
    /// runs slid past them dropped runs onto gym days, and the plan's same-day
    /// duplicate pruning then deleted the strength session outright (N6). Shifting
    /// the whole week by one delta preserves the spacing the plan was built with —
    /// which is the point of "pick up where I left off". Rest days stay put: they
    /// are gaps, not sessions, and nothing is lost by leaving them.
    func shiftMissedWorkoutsForward(
        plan: TrainingPlan,
        by days: Int,
        context: ModelContext
    ) throws {
        guard days > 0 else { return }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let hasFixedRace = plan.raceDate != nil

        let allWorkouts: [ScheduledWorkout] = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }
        let toShift: [ScheduledWorkout] = allWorkouts.filter { w in
            guard !w.isCompleted else { return false }
            guard w.scheduledDate >= startOfToday else { return false }
            let type = w.workoutType
            if type == .rest { return false }
            if hasFixedRace && type == .race { return false }
            return true
        }

        for workout in toShift {
            workout.scheduledDate = Calendar.current.date(
                byAdding: .day, value: days, to: workout.scheduledDate
            ) ?? workout.scheduledDate
        }

        if let newLast = toShift.max(by: { $0.scheduledDate < $1.scheduledDate }),
           newLast.scheduledDate > plan.endDate {
            plan.endDate = newLast.scheduledDate
        }

        try context.save()
    }

    /// Retires the active plan and generates a fresh one starting from today,
    /// preserving the original race date, goal time, and race type.
    ///
    /// The plan being replaced is **deactivated, never deleted** (N1). Deleting it
    /// cascaded through its weeks and every `ScheduledWorkout` in them, including
    /// completed ones — erasing the block from Plan History and unlinking the runs
    /// that fulfilled it. That is the same data loss H3 fixed for the plan-creation
    /// flows, and it fired from a button the app offers a runner who has fallen
    /// behind. Deleting a plan stays a deliberate action in the Plan History list.
    func rebuildPlan(
        replacing oldPlan: TrainingPlan,
        profile: UserProfile,
        context: ModelContext,
        unitPreference: UnitPreference = .metric
    ) throws {
        let startDate = Date().startOfDay
        let runDayIndices = profile.preferredRunDayIndices

        let newPlan: TrainingPlan
        if let raceDate = oldPlan.raceDate, let raceName = oldPlan.raceName {
            newPlan = trainingPlanService.generateRacePlan(
                profile: profile,
                startDate: startDate,
                raceDate: raceDate,
                raceName: raceName,
                runDayIndices: runDayIndices,
                unitPreference: unitPreference
            )
        } else {
            let remainingDays = Calendar.current.dateComponents(
                [.day], from: startDate, to: oldPlan.endDate
            ).day ?? 0
            let remainingWeeks = max(1, Int(ceil(Double(remainingDays + 1) / 7.0)))
            newPlan = trainingPlanService.generatePlan(
                profile: profile,
                startDate: startDate,
                numberOfWeeks: remainingWeeks,
                runDayIndices: runDayIndices,
                unitPreference: unitPreference
            )
        }

        newPlan.goalTimeSeconds = oldPlan.goalTimeSeconds
        newPlan.targetRace = oldPlan.targetRace

        // `save` enforces the single-active invariant by deactivating every other
        // plan, which retires `oldPlan` while keeping it (and its history) in the store.
        try planRepository.save(newPlan)
        try planRepository.setActive(newPlan)

        // The scheduler only clears entries for the plan it is syncing, so the retired
        // plan's workouts would otherwise stay on the Watch alongside the new block's.
        // Fire-and-forget: a failure here must not fail the rebuild the user asked for.
        Task { @MainActor [healthKitRepository] in
            try? await healthKitRepository.removeWorkoutPlans(for: oldPlan)
        }
    }

    // MARK: - Reset

    /// Everything **Settings → Reset All Data** has to tear down, in one place (N11).
    ///
    /// Deleting the SwiftData rows was only the visible half of a reset. Left behind,
    /// each of these outlives the data it describes:
    ///
    /// - up to 56 pending morning reminders keep firing for a plan that no longer exists;
    /// - the plan's WorkoutKit entries stay on the Watch and in Fitness, so the app
    ///   drops to onboarding while the Watch still offers last week's workouts;
    /// - the pending-review pointer and its snapshot can re-insert a deleted run on
    ///   the next launch, which is a reset that undoes itself.
    ///
    /// Order matters: the Watch entries are found through the plans that own them, so
    /// they have to be removed *before* the models are deleted.
    func resetAllData(context: ModelContext) async {
        await notificationService.cancelAllMorningReminders()

        let plans = (try? context.fetch(FetchDescriptor<TrainingPlan>())) ?? []
        for plan in plans {
            // Best-effort per plan: an unauthorized or unsupported scheduler must not
            // stop the reset the user explicitly confirmed.
            try? await healthKitRepository.removeWorkoutPlans(for: plan)
        }

        NotificationService.clearAllReviewState()
        pendingReviewWorkout = nil

        do {
            try context.delete(model: RunWorkout.self)
            try context.delete(model: StrengthWorkout.self)
            try context.delete(model: ScheduledWorkout.self)
            try context.delete(model: TrainingWeek.self)
            try context.delete(model: TrainingPlan.self)
            try context.delete(model: UserProfile.self)
            try context.delete(model: SavedRoute.self)
            try context.delete(model: DeletedWorkout.self)
            try context.save()
            AppLogger.log("Reset All Data completed for \(plans.count) plan(s).", label: "Data", level: .notice)
        } catch {
            AppLogger.log("Reset All Data failed: \(error)", label: "Data", level: .error)
        }
    }

    // MARK: Preview support

    /// In-memory container for SwiftUI previews and unit tests.
    static func preview() -> AppContainer {
        AppContainer(inMemory: true)
    }

    // MARK: - CloudKit diagnostics

    /// Logs CloudKit import/export lifecycle events from the underlying
    /// `NSPersistentCloudKitContainer` so we can confirm records are
    /// being pushed and pulled during development.
    private func configureCloudKitDiagnostics(cloudKitEnabled: Bool) {
        guard cloudKitEnabled else {
            AppLogger.log("Diagnostics disabled because CloudKit store is not active", label: "CloudKit", level: .debug)
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudKitEventChanged(_:)),
            name: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil
        )
    }

    @objc
    nonisolated private func handleCloudKitEventChanged(_ note: Notification) {
        guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
            as? NSPersistentCloudKitContainer.Event else {
            return
        }

        let eventType: String
        switch event.type {
        case .setup: eventType = "setup"
        case .import: eventType = "import"
        case .export: eventType = "export"
        @unknown default: eventType = "unknown"
        }

        let status: String
        let logLevel: AppLogger.Level
        if event.endDate == nil {
            status = "started"
            logLevel = .debug
        } else if let error = event.error {
            status = "failed (\(error.localizedDescription))"
            logLevel = .error
        } else {
            status = "finished"
            logLevel = .info
        }

        AppLogger.log("Event \(event.identifier) \(eventType) \(status)", label: "CloudKit", level: logLevel)

        guard let error = event.error else { return }
        for line in Self.cloudKitErrorDiagnosticLines(error, path: "event.error") {
            AppLogger.log(line, label: "CloudKit", level: .error)
        }
    }

    nonisolated private static func cloudKitErrorDiagnosticLines(_ error: Error, path: String) -> [String] {
        let nsError = error as NSError
        var lines = [
            "\(path): domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)"
        ]

        if let failureReason = nsError.localizedFailureReason, !failureReason.isEmpty {
            lines.append("\(path): failureReason=\(failureReason)")
        }
        if let recoverySuggestion = nsError.localizedRecoverySuggestion, !recoverySuggestion.isEmpty {
            lines.append("\(path): recoverySuggestion=\(recoverySuggestion)")
        }

        if nsError.domain == CKError.errorDomain {
            if let ckCode = CKError.Code(rawValue: nsError.code) {
                lines.append("\(path): ckCode=\(ckCode)")
            }
            if let requestUUIDEntry = nsError.userInfo.first(where: { entry in
                String(describing: entry.key).localizedCaseInsensitiveContains("uuid")
            }), let requestID = requestUUIDEntry.value as? String {
                lines.append("\(path): \(requestUUIDEntry.key)=\(requestID)")
            }
        }

        if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any], !partialErrors.isEmpty {
            lines.append("\(path): partialErrors.count=\(partialErrors.count)")
            for (itemID, value) in partialErrors.sorted(by: { "\($0.key)" < "\($1.key)" }) {
                guard let nestedError = value as? NSError else {
                    lines.append("\(path): partial[\(itemID)]=\(String(describing: value))")
                    continue
                }
                lines.append(
                    contentsOf: cloudKitErrorDiagnosticLines(
                        nestedError,
                        path: "\(path).partial[\(itemID)]"
                    )
                )
            }
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append(contentsOf: cloudKitErrorDiagnosticLines(underlying, path: "\(path).underlying"))
        }

        return lines
    }

}

// MARK: - EnvironmentKey

import SwiftUI

private struct AppContainerKey: EnvironmentKey {
    // Reached only when a view reads `@Environment(\.appContainer)` without an
    // ancestor injecting one — a wiring bug. Under the old default such a view
    // silently bound to a throwaway in-memory container and lost every write with
    // no error or log. Trap in debug so the missing injection surfaces at once; in
    // release, `assertionFailure` is a no-op and we hand back a fresh in-memory
    // container so a shipping build degrades instead of crashing. Computing this at
    // the access site (a `var`, not a `let`) keeps `assumeIsolated` on the main
    // actor where SwiftUI evaluates environment reads, rather than trapping on a
    // stray off-main first touch of a lazily-initialised `static let`.
    static var defaultValue: AppContainer {
        MainActor.assumeIsolated {
            assertionFailure(
                "appContainer was read without injection — add "
                + ".environment(\\.appContainer, container) above this view"
            )
            return AppContainer(inMemory: true)
        }
    }
}

extension EnvironmentValues {
    var appContainer: AppContainer {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}
