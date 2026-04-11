import Foundation
import HealthKit

// MARK: - Protocol

protocol HealthKitRepositoryProtocol: Sendable {
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    @MainActor func save(_ workout: RunWorkout) async throws -> String
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout]
    /// Saves an `HKWorkoutPlan` for each non-rest scheduled workout in the plan.
    /// The HealthKit UUID is written back to `workout.healthKitPlanID`.
    @MainActor func syncWorkoutPlans(for plan: TrainingPlan) async throws
    /// Removes previously saved `HKWorkoutPlan` objects for every workout in the plan.
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

    // MARK: - Workout plans (planned workouts → Apple Fitness)

    /// Creates one `HKWorkoutPlan` per non-rest scheduled workout and stores its UUID
    /// back on the model so duplicates and deletions can be managed later.
    @MainActor func syncWorkoutPlans(for plan: TrainingPlan) async throws {
        for week in plan.weeks {
            for workout in week.workouts where workout.workoutType != .rest {
                // Skip workouts that are already synced
                guard workout.healthKitPlanID == nil else { continue }

                let config = HKWorkoutConfiguration()
                config.activityType = .running
                config.locationType = .outdoor

                let hkPlan = HKWorkoutPlan(workoutConfiguration: config)
                try await store.save(hkPlan)
                workout.healthKitPlanID = hkPlan.uuid.uuidString
            }
        }
    }

    /// Deletes the `HKWorkoutPlan` objects that were previously saved for this training plan.
    @MainActor func removeWorkoutPlans(for plan: TrainingPlan) async throws {
        var plansToDelete: [HKObject] = []

        for week in plan.weeks {
            for workout in week.workouts {
                guard let uuidString = workout.healthKitPlanID,
                      let uuid = UUID(uuidString: uuidString)
                else { continue }

                if let hkPlan = try await fetchWorkoutPlan(uuid: uuid) {
                    plansToDelete.append(hkPlan)
                }
                workout.healthKitPlanID = nil
            }
        }

        guard !plansToDelete.isEmpty else { return }
        try await store.delete(plansToDelete)
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

    // MARK: - Private

    private func fetchWorkoutPlan(uuid: UUID) async throws -> HKWorkoutPlan? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObject(with: uuid)
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples?.first as? HKWorkoutPlan)
                }
            }
            store.execute(query)
        }
    }
}
