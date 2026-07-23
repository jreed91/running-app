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
