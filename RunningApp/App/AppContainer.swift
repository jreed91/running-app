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

    // MARK: Services

    let trainingPlanService: TrainingPlanService
    let workoutTrackerService: WorkoutTrackerService
    let notificationService: NotificationService

    // MARK: Init

    init() {
        let schema = Schema([
            UserProfile.self,
            RunWorkout.self,
            TrainingPlan.self,
            TrainingWeek.self,
            ScheduledWorkout.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }

        self.modelContainer = container

        let context = container.mainContext
        self.workoutRepository = WorkoutRepository(context: context)
        self.planRepository = PlanRepository(context: context)
        self.healthKitRepository = HealthKitRepository()

        self.trainingPlanService = TrainingPlanService()
        self.workoutTrackerService = WorkoutTrackerService()
        self.notificationService = NotificationService.shared
    }

    // MARK: Preview support

    /// In-memory container for SwiftUI previews and unit tests.
    static func preview() -> AppContainer {
        let container = AppContainer()
        return container
    }
}

// MARK: - EnvironmentKey

import SwiftUI

private struct AppContainerKey: EnvironmentKey {
    @MainActor static let defaultValue = AppContainer()
}

extension EnvironmentValues {
    var appContainer: AppContainer {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}
