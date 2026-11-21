import Foundation
import HealthKit

extension HealthKitRepositoryProtocol {
    /// No details: the default for test doubles and previews.
    func fetchImportedWorkoutDetails(forWorkoutID id: String) async -> ImportedWorkoutDetails? { nil }
}

extension HealthKitRepository {
    /// Reads the details off the workout itself: its activity type, the source that wrote
    /// it, and the heart-rate statistics saved with it. Not active energy: Stride does not
    /// ask to read it, and a new read type would re-prompt every runner for it.
    func fetchImportedWorkoutDetails(forWorkoutID id: String) async -> ImportedWorkoutDetails? {
        guard let workout = await hkWorkout(withID: id) else { return nil }
        let kind: ImportedWorkoutDetails.Kind
        switch workout.workoutActivityType {
        case .traditionalStrengthTraining: kind = .traditionalStrength
        case .functionalStrengthTraining: kind = .functionalStrength
        case .coreTraining: kind = .core
        default: kind = .other
        }
        let heartRate = workout.statistics(for: HKQuantityType(.heartRate))?
            .averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        return ImportedWorkoutDetails(
            kind: kind,
            sourceName: workout.sourceRevision.source.name,
            averageHeartRate: heartRate
        )
    }
}
