import Foundation
import Observation
import CoreData
import SwiftData

// MARK: - AppContainer

/// Central dependency-injection container.
///
/// Initialised once at app launch and injected into SwiftUI's environment by type —
/// `.environment(container)` at the root, `@Environment(AppContainer.self)` in a view —
/// the same shape `AppSettings` and `AuthService` already use. It was `ObservableObject`
/// behind a hand-written `EnvironmentKey` whose default had to *invent* a container for
/// a view nobody injected into, which is a wiring bug wearing a fallback (D4). There is
/// no default to get wrong now, and observation is per-property rather than per-object,
/// so a view that reads nothing off the container no longer redraws when one changes.
///
/// Services are singletons within the container lifetime.
@Observable
@MainActor
final class AppContainer {

    enum PersistenceMode: Equatable {
        case cloudKit
        case inMemory
        case localOnly
        case localFallback
        case recreatedLocalFallback
        case emergencyInMemory

        /// Shown on both Settings → Active Store and the CloudKit debug screen. One
        /// definition so the two cannot drift into describing the same launch differently.
        ///
        /// Deliberately not localized: this is a diagnostic label that appears in bug
        /// reports and in `docs/CLOUDKIT_VALIDATION.md`'s failure-sign list, and it has
        /// to be the same string whoever reads it.
        var displayName: String {
            switch self {
            case .cloudKit: "CloudKit"
            case .inMemory: "In-Memory"
            case .localOnly: "Local Only"
            case .localFallback: "Local Fallback"
            case .recreatedLocalFallback: "Recreated Local Store"
            case .emergencyInMemory: "Emergency In-Memory"
            }
        }
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
            case .storeMovedAside:
                String(localized: "Your training data couldn't be opened", comment: "Store-recovery alert title")
            case .runningInMemory:
                String(localized: "Running without saved data", comment: "Store-recovery alert title")
            }
        }

        var message: String {
            switch self {
            case .storeMovedAside(let backupName):
                let location = backupName.map {
                    String(localized: " It's kept on this device as \($0).", comment: "Where the unreadable store was kept")
                } ?? ""
                return String(
                    localized: """
                    Stride started with a fresh, empty database because your existing one \
                    couldn't be read by this version.\(location) Nothing was deleted — if you \
                    had iCloud Sync on, your data will come back down from iCloud shortly.
                    """,
                    comment: "Store-recovery alert body: the old store was set aside"
                )
            case .runningInMemory:
                return String(
                    localized: """
                    Stride couldn't open its database this time, so anything you record now \
                    will not be saved. Your existing data has been left untouched. Please \
                    restart the app; if this keeps happening, restart your device.
                    """,
                    comment: "Store-recovery alert body: running from memory"
                )
            }
        }
    }

    // MARK: SwiftData

    let modelContainer: ModelContainer
    let persistenceMode: PersistenceMode

    /// Set when the persistent store could not be opened normally, so the UI can tell
    /// the user what happened instead of silently running on a different store (C3).
    /// Cleared once acknowledged.
    var storeRecoveryNotice: StoreRecoveryNotice?

    /// The iCloud-sync preference the store was actually opened with. Settings
    /// compares the live preference against this to decide whether a restart is
    /// genuinely still pending, so the "restart to apply" note clears itself when
    /// the user toggles back rather than latching for the rest of the session.
    let syncPreferenceAtLaunch: Bool

    /// The CloudKit container this launch is mirroring into, or `nil` when it isn't.
    ///
    /// Read back off the configuration that was actually used rather than recomputed,
    /// so the debug screen reports what SwiftData was handed and not what the app
    /// intended — the distinction F1 turned on.
    let cloudKitContainerIdentifier: String?

    /// The most recent `NSPersistentCloudKitContainer` lifecycle events, newest first.
    ///
    /// Empty when sync is off, and empty until the first event arrives. Backs the
    /// CloudKit debug screen so a TestFlight tester can answer "is sync working?"
    /// without opening the Pulse console (F6).
    private(set) var recentCloudKitEvents: [CloudKitEventSummary] = []

    // MARK: Repositories

    let workoutRepository: WorkoutRepositoryProtocol
    let planRepository: PlanRepositoryProtocol
    let healthKitRepository: HealthKitRepositoryProtocol
    let routeRepository: RouteRepositoryProtocol

    // MARK: Services

    let trainingPlanService: TrainingPlanService
    /// Builds pregnancy plans. A sibling of `trainingPlanService` rather than a mode of it:
    /// the two share the SwiftData models and nothing else. See
    /// `docs/PREGNANCY_RUNNING_EVIDENCE.md`.
    let pregnancyPlanService: PregnancyPlanService
    let workoutTrackerService: WorkoutTrackerService
    let notificationService: NotificationService
    let workoutAnalyticsService: WorkoutAnalyticsService
    let routeGeniusService: RouteGeniusService
    let workoutSyncService: WorkoutSyncService
    let weatherService: WeatherService
    /// Reads tomorrow's forecast and decides whether the session in it needs to change
    /// (N39). Every number it acts on lives in `HeatAdaptationPolicy`; see
    /// `docs/HEAT_ADAPTATION_EVIDENCE.md`.
    let heatAdvisoryService: HeatAdvisoryService
    let aiCoachService: AICoachService

    /// Speaks split announcements during a run (U4). Owned here rather than by the run
    /// screen because it holds the app's audio session: one instance means one place that
    /// can leave the runner's music ducked, and it survives the HUD being dismissed
    /// mid-sentence.
    let runVoiceCoach: RunVoiceCoach

    /// Builds an Apple Music playlist shaped like a scheduled session (N40). Deliberately
    /// *not* related to `runVoiceCoach` despite both being about sound: this one writes a
    /// playlist into the runner's library and never plays anything, so it never touches the
    /// audio session the voice coach owns.
    let runPlaylistService: RunPlaylistService

    /// Creating, shifting, rebuilding, and destroying training plans (D2). The container
    /// wires it and hands it out; it does not orchestrate it.
    let planLifecycle: PlanLifecycleService

    /// Whether the active-run HUD is on screen, and the session state that has to survive
    /// it being closed (U7). Owned here for the same reason `runVoiceCoach` is: the run
    /// now outlives the screen that shows it, so nothing about it can live in the view.
    let activeRunPresentation: ActiveRunPresentation

    /// The run's Lock Screen and Dynamic Island presence (U5b). Wired into
    /// `workoutTrackerService` below, which is the only pulse in the app that keeps running
    /// while the phone is locked — the situation the activity exists for.
    let runActivityController: RunActivityController

    /// Which tab is on screen. Owned here so a widget's deep link, handled at the scene
    /// root, can drive a `TabView` several levels below it (B1).
    let appNavigation = AppNavigation()

    // MARK: Workout Review

    /// Listens to `NotificationService.syncedRunTaps` for this container's lifetime. Not
    /// cancelled in `deinit` — `deinit` is nonisolated and this is main-actor state — but
    /// the loop holds the container weakly and returns on the first tap after it is gone.
    @ObservationIgnored private var syncedRunTapTask: Task<Void, Never>?

    /// Set when a workout is synced from HealthKit (background or foreground) or when the user
    /// taps a "Run Synced" notification. Presenting a RunSummaryView sheet on this value lets
    /// the user review their workout and confirms the auto-link to today's planned workout.
    var pendingReviewWorkout: RunWorkout?

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

        // Shared on-disk URL keeps the CloudKit store and any local-fallback store
        // pointing at the same SQLite file. When CloudKit recovers, NSPersistentCloudKitContainer
        // picks up records that were written during an outage and pushes them automatically.
        let storeURL = storeURLOverride ?? StrideSchema.storeURL

        let cloudKitEnabled = forceCloudKit ?? Self.shouldUseCloudKit(syncEnabled: syncEnabled, inMemory: inMemory)

        let config = Self.makeConfiguration(
            schema: schema,
            storeURL: storeURL,
            inMemory: inMemory,
            cloudKitEnabled: cloudKitEnabled
        )

        // Fallback uses the SAME on-disk URL — data is never orphaned in a separate
        // store — and states `.none`, which is what makes it a genuinely different
        // configuration from `config` and so capable of recovering a CloudKit-caused
        // open failure. It used to omit `cloudKitDatabase:` entirely, which meant it
        // was the same mirrored configuration under a different name (F1).
        let localConfig = Self.makeConfiguration(
            schema: schema,
            storeURL: storeURL,
            inMemory: false,
            cloudKitEnabled: false
        )
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

                // Recreated with the *primary* configuration rather than `localConfig`:
                // with sync on, the fresh store has to be mirrored, or the alert's
                // promise — "if you had iCloud Sync on, your data will come back down
                // from iCloud shortly" — is false and the runner is left staring at an
                // empty app. With sync off it is `.none`, which is what it was anyway.
                if let c = try? modelContainerFactory(schema, [config]) {
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
        // The configuration that actually opened, not `config` — a fallback tier may
        // have replaced it, and each tier makes its own CloudKit decision.
        self.cloudKitContainerIdentifier = container.configurations
            .compactMap(\.cloudKitContainerIdentifier)
            .first
        self.storeRecoveryNotice = StoreRecoveryNotice(
            mode: persistenceMode,
            movedAsideStoreName: movedAsideStoreName
        )

        let context = container.mainContext
        self.workoutRepository = WorkoutRepository(context: context)
        let planRepo = PlanRepository(context: context)
        self.planRepository = planRepo
        let hkRepository = HealthKitRepository()
        self.healthKitRepository = hkRepository
        self.routeRepository = RouteRepository(context: context)

        let planService = TrainingPlanService()
        self.trainingPlanService = planService
        self.pregnancyPlanService = PregnancyPlanService()
        let tracker = WorkoutTrackerService()
        self.workoutTrackerService = tracker
        let activityController = RunActivityController()
        self.runActivityController = activityController
        // The tracker drives the Live Activity, so it is handed the presenter rather than
        // reaching for it: three verbs (started, updated, ended) instead of a dependency on
        // ActivityKit inside the service that records the run (U5b).
        tracker.activityPresenter = activityController
        let notifications = NotificationService.shared
        self.notificationService = notifications
        self.workoutAnalyticsService = WorkoutAnalyticsService()
        self.routeGeniusService = RouteGeniusService(
            session: PulseIntegrationService.makeInstrumentedURLSession()
        )
        let weather = WeatherService()
        self.weatherService = weather
        self.heatAdvisoryService = HeatAdvisoryService(
            weatherService: weather,
            notificationService: notifications
        )
        self.aiCoachService = AICoachService()
        self.runVoiceCoach = RunVoiceCoach()
        self.runPlaylistService = RunPlaylistService()
        self.activeRunPresentation = ActiveRunPresentation()
        self.workoutSyncService = WorkoutSyncService(
            healthKitRepository: hkRepository,
            notificationService: notifications,
            weatherService: weather,
            context: context
        )
        self.planLifecycle = PlanLifecycleService(
            trainingPlanService: planService,
            planRepository: planRepo,
            healthKitRepository: hkRepository,
            notificationService: notifications
        )

        self.configureCloudKitDiagnostics(cloudKitEnabled: cloudKitEnabled)

        // Wire background-sync callback: surface the review sheet immediately if the app is
        // in the foreground when the sync fires. UserDefaults is written by WorkoutSyncService
        // so a cold launch also surfaces the workout via checkForPendingReviewWorkout().
        workoutSyncService.onWorkoutsSynced = { [weak self] workouts in
            guard let self, let first = workouts.first else { return }
            self.pendingReviewWorkout = first
        }

        // Notification taps arrive as a stream rather than a stored callback on the
        // notification singleton, which whichever container was built last used to own
        // (D4). `self` is re-checked on every element — the shape
        // `AppSettings.observeExternalChanges` uses — so this task keeps no strong
        // reference to the container between taps and falls out once it is gone.
        syncedRunTapTask = Task { @MainActor [weak self] in
            for await idString in notifications.syncedRunTaps {
                guard let self else { return }
                self.surfacePendingReviewWorkout(idString: idString)
            }
        }
    }

    // MARK: - Store configuration

    /// Builds the `ModelConfiguration` for one store open.
    ///
    /// **Every configuration states `cloudKitDatabase` explicitly, including the ones
    /// that do not sync.** The parameter defaults to `.automatic`, which Apple documents
    /// as "enables managed CloudKit sync using the primary ubiquity container from the
    /// app's entitlements" — and `Stride.entitlements` names one. So a configuration that
    /// omitted the argument mirrored to iCloud whatever it was called: the local-only
    /// path, the fallback, the simulator carve-out, and `IntentDataProvider` all synced,
    /// and the iCloud Sync toggle reported "Local Only" while still uploading every run
    /// (F1). Naming the option is the whole fix, so do not drop it from a new call site.
    ///
    /// See `docs/CLOUDKIT_ANALYSIS_2026-07-28.md` §3 F1.
    ///
    /// Pure and static so the sync decision is assertable off-device —
    /// `CloudKitConfigurationTests` reads `cloudKitContainerIdentifier` back off the
    /// result, which is the only part of this that a simulator can check.
    static func makeConfiguration(
        schema: Schema,
        storeURL: URL,
        inMemory: Bool,
        cloudKitEnabled: Bool,
        containerID: String = StrideSchema.cloudKitContainerID
    ) -> ModelConfiguration {
        if inMemory {
            // An in-memory store has nothing to mirror, but `.automatic` here would still
            // have SwiftData resolve a container from the entitlements. Say `.none`.
            return ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }
        if cloudKitEnabled {
            return ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .private(containerID)
            )
        }
        return ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
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
        let memConfig = Self.makeConfiguration(
            schema: schema,
            storeURL: StrideSchema.storeURL,
            inMemory: true,
            cloudKitEnabled: false
        )
        do {
            return (try factory(schema, [memConfig]), .emergencyInMemory)
        } catch {
            fatalError("[AppContainer] In-memory ModelContainer failed — SwiftData is broken on this device: \(error)")
        }
    }

    /// Whether this launch should mirror to CloudKit.
    ///
    /// The simulator carve-out is not a platform limitation — Apple states you "can run
    /// and test Core Data with CloudKit apps using Simulator". It is here because the
    /// unit-test suite runs in the simulator and builds real file-backed containers
    /// (`AppContainerTests` does, with a `storeURLOverride`), so without it every test
    /// run would write into the team's real development container. Device validation
    /// per `docs/CLOUDKIT_VALIDATION.md` remains how sync is actually verified.
    ///
    /// Until F1 was fixed this returned `false` and then handed back a configuration
    /// that synced anyway, so none of the above was true.
    static func shouldUseCloudKit(syncEnabled: Bool, inMemory: Bool) -> Bool {
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
            context.saveOrLog("the restored review snapshot")
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

    // MARK: - Reset

    /// Clears the in-memory pointer at the review sheet, then hands the teardown to
    /// `PlanLifecycleService`. The pointer is the container's own state — a strong
    /// reference to a `RunWorkout` that is about to be deleted — so it goes first.
    func resetAllData(context: ModelContext) async {
        pendingReviewWorkout = nil
        // The advisory and its dismissals live in UserDefaults, outside the store the
        // lifecycle service is about to tear down — the same reason the widget snapshot is
        // cleared below. Dismissals go too: they name workouts that will not exist a
        // moment from now.
        await heatAdvisoryService.clear(includingDismissals: true)
        // Same reasoning for the run-playlist links: they name workouts that are about to
        // stop existing. The playlists themselves stay — they are in the runner's Apple
        // Music library, not Stride's, and this button does not get to delete somebody's
        // music.
        RunPlaylistStore.removeAll()
        await planLifecycle.resetAllData(context: context)
        // The App Group container is outside the store `PlanLifecycleService` just tore
        // down, so without this the Home Screen would be the one place the deleted plan
        // survived (B1).
        WidgetRefreshService.clear()
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

        // Flattened here, at the notification boundary: the event is not `Sendable` and
        // this callback runs on whatever thread CloudKit posted from, so nothing past
        // this line may touch it.
        let summary = CloudKitEventSummary(event: event)

        let logLevel: AppLogger.Level = switch summary.status {
        case .started: .debug
        case .finished: .info
        case .failed: .error
        }
        AppLogger.log(summary.logLine, label: "CloudKit", level: logLevel)

        if let error = event.error {
            for line in CloudKitDiagnostics.errorDiagnosticLines(error, path: "event.error") {
                AppLogger.log(line, label: "CloudKit", level: .error)
            }
        }

        Task { @MainActor [weak self] in
            self?.record(summary)
        }
    }

    /// Keeps the newest events for the CloudKit debug screen, newest first.
    private func record(_ summary: CloudKitEventSummary) {
        // One operation posts a "started" event and then a "finished"/"failed" event
        // under the same identifier. Replacing in place keeps the list a list of
        // operations rather than of notifications.
        if let existing = recentCloudKitEvents.firstIndex(where: {
            $0.identifier == summary.identifier && $0.kind == summary.kind
        }) {
            recentCloudKitEvents.remove(at: existing)
        }
        recentCloudKitEvents.insert(summary, at: 0)
        if recentCloudKitEvents.count > CloudKitDiagnostics.eventHistoryLimit {
            recentCloudKitEvents.removeLast(recentCloudKitEvents.count - CloudKitDiagnostics.eventHistoryLimit)
        }
    }

}
