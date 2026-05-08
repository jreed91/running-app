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

    // MARK: SwiftData

    let modelContainer: ModelContainer
    let persistenceMode: PersistenceMode

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

        let schema = Schema([
            UserProfile.self,
            RunWorkout.self,
            StrengthWorkout.self,
            TrainingPlan.self,
            TrainingWeek.self,
            ScheduledWorkout.self,
            SavedRoute.self,
            DeletedWorkout.self
        ])
        // Read the preference set during onboarding / Settings.
        // UserDefaults is checked directly here because AppSettings doesn't
        // exist yet at the point AppContainer is initialized.
        let syncEnabled = syncEnabledOverride ?? AppSettings.syncedICloudEnabled()

        // Explicit container ID so every code path targets the same CloudKit store.
        let ckContainerID = "iCloud.com.running.stride"

        // Shared on-disk URL keeps the CloudKit store and any local-fallback store
        // pointing at the same SQLite file. When CloudKit recovers, NSPersistentCloudKitContainer
        // picks up records that were written during an outage and pushes them automatically.
        let storeURL = storeURLOverride ?? URL.applicationSupportDirectory.appending(path: "Stride.store")

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
            if let c = try? modelContainerFactory(schema, [localConfig]) {
                container = c
                persistenceMode = .localFallback
                AppLogger.log("Tier1: local-only store OK (data will sync when CloudKit recovers)", label: "AppContainer", level: .notice)
            } else {
                // Tier 2 — delete the on-disk store and recreate local-only.
                AppLogger.log("Tier2: deleting store at \(storeURL.path)", label: "AppContainer", level: .warning)
                for suffix in ["", "-shm", "-wal"] {
                    try? FileManager.default.removeItem(
                        at: URL(fileURLWithPath: storeURL.path + suffix)
                    )
                }

                if let c = try? modelContainerFactory(schema, [localConfig]) {
                    container = c
                    persistenceMode = .recreatedLocalFallback
                    AppLogger.log("Tier2: fresh local store created OK", label: "AppContainer", level: .notice)
                } else {
                    // Tier 3 — in-memory; data won't persist but the app won't crash on launch.
                    AppLogger.log("Tier3: all persistent tiers failed — using in-memory store", label: "AppContainer", level: .critical)
                    let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    do {
                        container = try modelContainerFactory(schema, [memConfig])
                        persistenceMode = .emergencyInMemory
                    } catch let tier3Error {
                        fatalError("[AppContainer] In-memory ModelContainer failed — SwiftData is broken on this device: \(tier3Error)")
                    }
                }
            }
        }

        self.modelContainer = container
        self.persistenceMode = persistenceMode

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
        self.routeGeniusService = RouteGeniusService()
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
    func attachWeather(to workout: RunWorkout, coordinate: Coordinate) async {
        AppLogger.log(
            "Attaching weather to workout \(workout.id) at (\(String(format: "%.4f", coordinate.latitude)), \(String(format: "%.4f", coordinate.longitude)))",
            label: "WeatherKit",
            level: .debug
        )
        guard let summary = await weatherService.fetchWeather(at: coordinate, date: workout.date) else {
            AppLogger.log("Weather fetch returned nil for workout \(workout.id) — skipping attach", label: "WeatherKit", level: .warning)
            return
        }
        workout.weather = summary
        try? modelContainer.mainContext.save()
        AppLogger.log("Weather attached to workout \(workout.id)", label: "WeatherKit", level: .info)
    }

    // MARK: - Workout Review

    /// Checks UserDefaults for a workout that was synced while the app was not in the foreground
    /// and surfaces it for review. Called at launch so cold-opens also trigger the review sheet.
    func checkForPendingReviewWorkout() {
        guard
            let idString = UserDefaults.standard.string(forKey: "pendingReviewWorkoutID"),
            pendingReviewWorkout == nil
        else { return }
        surfacePendingReviewWorkout(idString: idString)
    }

    private func surfacePendingReviewWorkout(idString: String) {
        guard let uuid = UUID(uuidString: idString) else {
            AppLogger.log("Ignored pending review with invalid UUID \(idString)", label: "Notifications", level: .warning)
            return
        }
        let all = (try? modelContainer.mainContext.fetch(FetchDescriptor<RunWorkout>())) ?? []
        let workout: RunWorkout
        if let storedWorkout = all.first(where: { $0.id == uuid }) {
            workout = storedWorkout
        } else if let snapshotWorkout = notificationService.workoutFromReviewSnapshot(idString: idString) {
            modelContainer.mainContext.insert(snapshotWorkout)
            try? modelContainer.mainContext.save()
            workout = snapshotWorkout
        } else {
            AppLogger.log("Could not find workout for pending review id=\(idString); fetched \(all.count) workouts", label: "Notifications", level: .warning)
            return
        }
        pendingReviewWorkout = workout
        UserDefaults.standard.removeObject(forKey: "pendingReviewWorkoutID")
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
        apiKey: String,
        modelOverride: String,
        unitPreference: UnitPreference = .metric
    ) async -> ScheduledWorkout {
        await aiCoachService.adaptScheduledWorkoutWithProvider(
            scheduled: scheduled,
            recentHistory: history,
            profile: profile,
            provider: provider,
            apiKey: apiKey,
            modelOverride: modelOverride,
            unitPreference: unitPreference
        ) ?? scheduled
    }

    /// Returns AI-adapted workouts for a plan batch using a single provider request.
    func adaptedWorkouts(
        scheduled workouts: [ScheduledWorkout],
        history: [RunWorkout],
        profile: UserProfile,
        provider: AIProvider,
        apiKey: String,
        modelOverride: String,
        unitPreference: UnitPreference = .metric,
        onChunk: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> [UUID: ScheduledWorkout] {
        await aiCoachService.adaptScheduledWorkoutsWithProvider(
            scheduled: workouts,
            recentHistory: history,
            profile: profile,
            provider: provider,
            apiKey: apiKey,
            modelOverride: modelOverride,
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

    /// Shifts all future uncompleted non-rest workouts forward by `days` calendar days.
    /// Extends `plan.endDate` if any shifted workout falls beyond it.
    /// Race workouts are excluded when the plan has a fixed raceDate.
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
            if type == .rest || type == .strength || type == .crossTraining { return false }
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

    /// Deletes the active plan and generates a fresh one starting from today,
    /// preserving the original race date, goal time, and race type.
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

        try planRepository.delete(oldPlan)
        try planRepository.save(newPlan)
        try planRepository.setActive(newPlan)
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
    nonisolated(unsafe) static let defaultValue: AppContainer = MainActor.assumeIsolated {
        AppContainer(inMemory: true)
    }
}

extension EnvironmentValues {
    var appContainer: AppContainer {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}
