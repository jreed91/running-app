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
    let dataMigrationService: DataMigrationService
    let weatherService: WeatherService

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
            TrainingPlan.self,
            TrainingWeek.self,
            ScheduledWorkout.self,
            SavedRoute.self
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
        self.workoutSyncService = WorkoutSyncService(
            healthKitRepository: hkRepository,
            notificationService: notifications,
            weatherService: weather,
            context: context
        )

        self.dataMigrationService = DataMigrationService()
        self.dataMigrationService.runIfNeeded(context: context)
        self.configureCloudKitDiagnostics(cloudKitEnabled: cloudKitEnabled)
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
        guard let summary = await weatherService.fetchWeather(at: coordinate, date: workout.date) else { return }
        workout.weather = summary
        try? modelContainer.mainContext.save()
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

    /// Returns an adapted ``ScheduledWorkout`` based on the runner's recent history.
    /// If history is empty the original workout is returned unchanged.
    func adaptedWorkout(
        scheduled: ScheduledWorkout,
        history: [RunWorkout],
        profile: UserProfile,
        unitPreference: UnitPreference = .metric
    ) -> ScheduledWorkout {
        guard !history.isEmpty else { return scheduled }
        return trainingPlanService.adaptWorkout(
            scheduled: scheduled,
            history: history,
            profile: profile,
            unitPreference: unitPreference
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
            if let requestID = nsError.userInfo[CKErrorRequestUUIDKey] as? String {
                lines.append("\(path): requestUUID=\(requestID)")
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
