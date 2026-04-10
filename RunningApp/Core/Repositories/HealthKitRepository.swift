import Foundation
import HealthKit

// MARK: - Protocol

protocol HealthKitRepositoryProtocol: Sendable {
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    func save(_ workout: RunWorkout) async throws -> String
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout]
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

    func save(_ workout: RunWorkout) async throws -> String {
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
