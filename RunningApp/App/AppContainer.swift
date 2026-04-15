import Foundation
import SwiftData

// MARK: - AppContainer

/// Central dependency-injection container.
///
/// Initialised once at app launch and injected via SwiftUI's `Environment`.
/// Services are singletons within the container lifetime.
@MainActor
final class AppContainer: ObservableObject {

    // MARK: SwiftData

    let modelContainer: ModelContainer

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

    // MARK: Init

    init(inMemory: Bool = false) {
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
        let syncEnabled: Bool
        if UserDefaults.standard.object(forKey: AppSettings.iCloudSyncKey) != nil {
            syncEnabled = UserDefaults.standard.bool(forKey: AppSettings.iCloudSyncKey)
        } else {
            syncEnabled = true   // first-launch default: sync on
        }

        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if syncEnabled {
            config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }

        let localConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
            print("[AppContainer v4] Store opened OK (syncEnabled=\(syncEnabled))")
        } catch let primaryError {
            print("[AppContainer v4] Primary store failed: \(primaryError)")
            guard !inMemory else {
                // In-memory configs should never fail; if they do the schema is broken.
                fatalError("[AppContainer v4] In-memory ModelContainer failed: \(primaryError)")
            }

            // Tier 1 — local-only (skip CloudKit).
            if let c = try? ModelContainer(for: schema, configurations: [localConfig]) {
                container = c
                print("[AppContainer v4] Tier1: local-only store OK")
            } else {
                // Tier 2 — delete the on-disk store and recreate.
                let storeURL = localConfig.url
                print("[AppContainer v4] Tier2: deleting store at \(storeURL.path)")
                for suffix in ["", "-shm", "-wal"] {
                    try? FileManager.default.removeItem(
                        at: URL(fileURLWithPath: storeURL.path + suffix)
                    )
                }

                if let c = try? ModelContainer(for: schema, configurations: [localConfig]) {
                    container = c
                    print("[AppContainer v4] Tier2: fresh store created OK")
                } else {
                    // Tier 3 — in-memory fallback; data won't persist this session
                    // but the app will not crash.
                    print("[AppContainer v4] Tier3: all persistent tiers failed — using in-memory store")
                    let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    // swiftlint:disable:next force_try
                    container = try! ModelContainer(for: schema, configurations: [memConfig])
                }
            }
        }

        self.modelContainer = container

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
        self.workoutSyncService = WorkoutSyncService(
            healthKitRepository: hkRepository,
            notificationService: notifications,
            context: context
        )

        self.dataMigrationService = DataMigrationService()
        self.dataMigrationService.runIfNeeded(context: context)
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

    // MARK: - Schedule management

    /// Redistributes uncompleted future workouts to match the given run day indices.
    func rescheduleWorkouts(
        in plan: TrainingPlan,
        newDayIndices: [Int],
        profile: UserProfile?
    ) {
        trainingPlanService.applyNewRunDays(to: plan, newDayIndices: newDayIndices, profile: profile)
    }

    // MARK: Preview support

    /// In-memory container for SwiftUI previews and unit tests.
    static func preview() -> AppContainer {
        AppContainer(inMemory: true)
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
