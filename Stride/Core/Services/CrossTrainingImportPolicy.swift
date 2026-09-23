import Foundation
import HealthKit

// MARK: - CrossTrainingImportPolicy

/// Which Apple Health workouts are imported as cross-training, and which are big enough
/// to keep (B8).
///
/// Kept out of `HealthKitRepository` so the importer only carries the plumbing, and next
/// to `RunEffortPolicy` in spirit: the floor a session has to clear is a product rule,
/// not a HealthKit detail.
enum CrossTrainingImportPolicy {

    /// The activities a plan's cross-training day means: bike, pool, erg, elliptical,
    /// stairs, and a session the Watch just calls cross-training or mixed cardio.
    ///
    /// Not hiking (a day on a mountain is not a 30-minute cross-training slot, and walk
    /// import leaves it out for the same reason), not strength or HIIT (the strength pass
    /// owns the gym), and not anything with a ball or a partner.
    static let activityTypes: [HKWorkoutActivityType] = [
        .cycling,
        .handCycling,
        .swimming,
        .rowing,
        .elliptical,
        .stairClimbing,
        .stairs,
        .stepTraining,
        .crossTraining,
        .mixedCardio
    ]

    /// Duration a session must reach, in seconds.
    ///
    /// Time only, no distance: an elliptical or a stair session records none, and a
    /// ride's or a swim's says nothing a run's would. Ten minutes is past the ride to the
    /// station and short of any cross-training day a plan prescribes.
    static let minimumDurationSeconds: Double = 10 * 60

    /// Whether a session of this length is worth importing.
    static func isRealSession(durationSeconds: Double) -> Bool {
        durationSeconds >= minimumDurationSeconds
    }
}

extension HealthKitRepository.ImportKind {

    /// Whether walking/running distance and steps belong to this activity — the source of
    /// a recovered distance, the splits and the cadence. None of the three means anything
    /// for a ride or a swim, and a phone in a pocket on an elliptical would even count
    /// "distance" for one, so the importer reads none of them for cross-training (B8).
    var readsFootSamples: Bool {
        switch self {
        case .run, .walk: return true
        case .crossTraining: return false
        }
    }
}
