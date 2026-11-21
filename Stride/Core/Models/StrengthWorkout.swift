import Foundation
import SwiftData

@Model
final class StrengthWorkout {
    #Index<StrengthWorkout>([\.id], [\.date])

    var id: UUID = UUID()
    var date: Date = Date()
    var durationSeconds: Double = 0
    var notes: String?
    /// HealthKit workout UUID string, set after syncing from HealthKit.
    var healthKitWorkoutID: String?
    /// JSON-encoded `[CompletedStrengthSet]` — the sets actually logged during the session.
    var completedSetsData: Data?

    /// Back-reference to the ``ScheduledWorkout`` this strength session fulfilled, if any.
    /// The inverse is declared on ``ScheduledWorkout/completedStrengthWorkout``; SwiftData infers it here.
    var scheduledWorkout: ScheduledWorkout?
    /// Scalar backup for CloudKit relationship repair.
    var linkedScheduledWorkoutID: UUID?

    init(date: Date, durationSeconds: Double, notes: String? = nil) {
        self.id = UUID()
        self.date = date
        self.durationSeconds = durationSeconds
        self.notes = notes
        self.createdAt = date
    }

    var createdAt: Date = Date()
}

// MARK: - Computed helpers

extension StrengthWorkout {
    var completedSets: [CompletedStrengthSet] {
        get { completedSetsData?.decode([CompletedStrengthSet].self) ?? [] }
        set { completedSetsData = newValue.isEmpty ? nil : .encoded(newValue, keeping: completedSetsData) }
    }
}

// MARK: - As values

extension StrengthWorkout {
    /// The session as ``StrengthProgression`` reads it: every set named, every load in
    /// kilograms where one can be known.
    ///
    /// A set logged before names were stored takes its name from the scheduled workout's
    /// plan by index; one whose plan is gone, or whose index no longer exists in it, is
    /// left out rather than guessed. A text weight from before weights were numbers is
    /// read in `unit` when it has no unit of its own.
    func sessionLog(unit: UnitPreference) -> StrengthSessionLog {
        let planExercises = scheduledWorkout?.strengthPlan?.exercises ?? []
        let sets = completedSets.compactMap { set -> LoggedStrengthSet? in
            let name = set.exerciseName
                ?? (planExercises.indices.contains(set.exerciseIndex) ? planExercises[set.exerciseIndex].name : nil)
            guard let name else { return nil }
            return LoggedStrengthSet(
                exerciseName: name,
                reps: set.completedReps,
                weightKilograms: set.weightKilograms
                    ?? StrengthProgression.legacyWeightKilograms(from: set.actualWeight, unit: unit),
                skipped: set.skipped
            )
        }
        return StrengthSessionLog(date: date, sets: sets)
    }
}

extension StrengthWorkout {
    /// The session as ``StrengthImportMerge`` reads it.
    var mergeSession: StrengthImportMerge.Session {
        StrengthImportMerge.Session(
            id: id,
            healthKitWorkoutID: healthKitWorkoutID,
            start: date,
            durationSeconds: durationSeconds
        )
    }
}
