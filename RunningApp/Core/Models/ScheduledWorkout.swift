import Foundation
import SwiftData

@Model
final class ScheduledWorkout {
    var id: UUID
    var scheduledDate: Date
    var workoutType: WorkoutType
    var targetDistanceMeters: Double?
    /// Lower bound of target pace range in seconds/km.
    var targetPaceLowerBound: Double?
    /// Upper bound of target pace range in seconds/km.
    var targetPaceUpperBound: Double?
    var isCompleted: Bool
    var notes: String?

    /// EventKit calendar event identifier for this planned workout.
    var calendarEventID: String?

    /// JSON-encoded `[WorkoutInterval]` — only set for interval sessions.
    var intervalsData: Data?

    var week: TrainingWeek?

    @Relationship(deleteRule: .nullify)
    var completedWorkout: RunWorkout?

    // MARK: Computed helpers

    var intervals: [WorkoutInterval] {
        get {
            guard let data = intervalsData else { return [] }
            return (try? JSONDecoder().decode([WorkoutInterval].self, from: data)) ?? []
        }
        set {
            intervalsData = try? JSONEncoder().encode(newValue)
        }
    }

    var targetPaceRange: ClosedRange<Double>? {
        guard let lo = targetPaceLowerBound, let hi = targetPaceUpperBound, lo <= hi else { return nil }
        return lo...hi
    }

    init(
        scheduledDate: Date,
        workoutType: WorkoutType,
        targetDistanceMeters: Double? = nil,
        targetPaceLowerBound: Double? = nil,
        targetPaceUpperBound: Double? = nil,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.scheduledDate = scheduledDate
        self.workoutType = workoutType
        self.targetDistanceMeters = targetDistanceMeters
        self.targetPaceLowerBound = targetPaceLowerBound
        self.targetPaceUpperBound = targetPaceUpperBound
        self.notes = notes
        self.isCompleted = false
    }
}
