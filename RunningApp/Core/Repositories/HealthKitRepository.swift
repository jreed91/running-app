import Foundation
import HealthKit

// MARK: - Protocol

protocol HealthKitRepositoryProtocol: Sendable {
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    @MainActor func save(_ workout: RunWorkout) async throws -> String
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout]
    /// Assigns a local tracking ID to each non-rest scheduled workout in the plan.
    @MainActor func syncWorkoutPlans(for plan: TrainingPlan) async throws
    /// Clears the local tracking IDs for every workout in the plan.
    @MainActor func removeWorkoutPlans(for plan: TrainingPlan) async throws
}

// MARK: - Live implementation

final class HealthKitRepository: HealthKitRepositoryProtocol, @unchecked Sendable {
    private let store = HKHealthStore()

    private static let shareTypes: Set<HKSampleType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.heartRate)
    ]

    private static let readTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.heartRate),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.vo2Max)
    ]

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(
            toShare: Self.shareTypes,
            read: Self.readTypes
        )
    }

    // MARK: - Completed workout

    @MainActor func save(_ workout: RunWorkout) async throws -> String {
        let hkWorkout = HKWorkout(
            activityType: .running,
            start: workout.date,
            end: workout.date.addingTimeInterval(workout.durationSeconds),
            duration: workout.durationSeconds,
            totalEnergyBurned: nil,
            totalDistance: HKQuantity(unit: .meter(), doubleValue: workout.distanceMeters),
            metadata: ["RunningAppWorkoutID": workout.id.uuidString]
        )
        try await store.save(hkWorkout)
        return hkWorkout.uuid.uuidString
    }

    // MARK: - Workout plans (planned workouts)

    /// Assigns a stable local UUID to each non-rest scheduled workout so the app
    /// can track which workouts have been "planned". HealthKit has no public API
    /// for storing planned workouts, so the ID is kept in the SwiftData model only.
    @MainActor func syncWorkoutPlans(for plan: TrainingPlan) async throws {
        for week in plan.weeks {
            for workout in week.workouts where workout.workoutType != .rest {
                guard workout.healthKitPlanID == nil else { continue }
                workout.healthKitPlanID = UUID().uuidString
            }
        }
    }

    /// Clears the local plan IDs that were previously assigned for this training plan.
    @MainActor func removeWorkoutPlans(for plan: TrainingPlan) async throws {
        for week in plan.weeks {
            for workout in week.workouts {
                workout.healthKitPlanID = nil
            }
        }
    }

    // MARK: - Historical workout fetch

    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        let runningPredicate = HKQuery.predicateForWorkouts(with: .running)
        let datePredicate = HKQuery.predicateForSamples(
            withStart: startDate, end: endDate, options: .strictStartDate
        )
        let compound = NSCompoundPredicate(
            andPredicateWithSubpredicates: [runningPredicate, datePredicate]
        )
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: compound,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
                }
            }
            store.execute(query)
        }
    }


}
