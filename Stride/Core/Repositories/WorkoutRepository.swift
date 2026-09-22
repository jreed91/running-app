import Foundation
import SwiftData

// MARK: - Protocol

/// Runs, not walks.
///
/// Every fetch here returns running history and skips imported walks (N38) — these
/// results feed pace refresh, plan adaptation and "your last run", none of which a walk
/// belongs in. History, which shows everything the runner recorded, queries the store
/// directly rather than through this.
protocol WorkoutRepositoryProtocol {
    func save(_ workout: RunWorkout) throws
    func fetchAll() throws -> [RunWorkout]
    func fetch(from startDate: Date, to endDate: Date) throws -> [RunWorkout]
    func fetchRecent(limit: Int) throws -> [RunWorkout]
    func delete(_ workout: RunWorkout) throws
    func delete(_ workout: StrengthWorkout) throws
}

// MARK: - SwiftData implementation

final class WorkoutRepository: WorkoutRepositoryProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func save(_ workout: RunWorkout) throws {
        context.insert(workout)
        try context.save()
    }

    func fetchAll() throws -> [RunWorkout] {
        try context.fetch(RunWorkout.runsOnlyDescriptor())
    }

    func fetch(from startDate: Date, to endDate: Date) throws -> [RunWorkout] {
        let walkRaw = WorkoutType.walk.rawValue
        let crossTrainingRaw = WorkoutType.crossTraining.rawValue
        let descriptor = FetchDescriptor<RunWorkout>(
            predicate: #Predicate {
                $0.date >= startDate && $0.date <= endDate
                    && $0.workoutTypeRaw != walkRaw && $0.workoutTypeRaw != crossTrainingRaw
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func fetchRecent(limit: Int) throws -> [RunWorkout] {
        // The walk exclusion is in the fetch, not applied to its result: `fetchRecent(1)`
        // filtered afterwards returns nothing at all whenever the newest entry is a walk.
        try context.fetch(RunWorkout.runsOnlyDescriptor(fetchLimit: limit))
    }

    /// Deletes a run and repairs every invariant a raw `context.delete` would leave broken:
    ///   - writes a `DeletedWorkout` tombstone so the run is never re-imported from HealthKit,
    ///   - unlinks the scheduled workout it fulfilled and clears `isCompleted` so adherence
    ///     stats (and the intents' `todaysRun()`) stop counting a workout that no longer exists.
    func delete(_ workout: RunWorkout) throws {
        if let hkID = workout.healthKitWorkoutID {
            context.insert(DeletedWorkout(healthKitWorkoutID: hkID))
        }
        if let scheduled = workout.scheduledWorkout {
            scheduled.completedWorkout = nil
            scheduled.linkedRunWorkoutID = nil
            scheduled.isCompleted = false
        }
        workout.linkedScheduledWorkoutID = nil
        context.delete(workout)
        try context.save()
    }

    /// Deletes a strength workout with the same invariant repair as the run path:
    /// tombstones the HealthKit source (strength sessions can also arrive from the Watch)
    /// and resets the scheduled day so it no longer counts as completed.
    func delete(_ workout: StrengthWorkout) throws {
        if let hkID = workout.healthKitWorkoutID {
            context.insert(DeletedWorkout(healthKitWorkoutID: hkID))
        }
        if let scheduled = workout.scheduledWorkout {
            scheduled.completedStrengthWorkout = nil
            scheduled.linkedStrengthWorkoutID = nil
            scheduled.isCompleted = false
        }
        workout.linkedScheduledWorkoutID = nil
        context.delete(workout)
        try context.save()
    }
}
