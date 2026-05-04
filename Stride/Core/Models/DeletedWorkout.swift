import Foundation
import SwiftData

/// Tombstone that prevents a deleted HealthKit-sourced workout from being re-imported
/// by ``WorkoutSyncService`` on subsequent syncs.
///
/// When a ``RunWorkout`` that has a ``RunWorkout/healthKitWorkoutID`` is deleted, a
/// `DeletedWorkout` record is written with that ID. The sync service excludes any
/// HealthKit workout whose UUID appears in this table.
@Model
final class DeletedWorkout {
    #Index<DeletedWorkout>([\.healthKitWorkoutID])

    var id: UUID = UUID()
    /// The HealthKit workout UUID string that must never be re-imported.
    var healthKitWorkoutID: String = ""
    var deletedAt: Date = Date()

    init(healthKitWorkoutID: String) {
        self.id = UUID()
        self.healthKitWorkoutID = healthKitWorkoutID
        self.deletedAt = Date()
    }
}
