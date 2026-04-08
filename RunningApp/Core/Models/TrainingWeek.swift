import Foundation
import SwiftData

@Model
final class TrainingWeek {
    var id: UUID
    var weekNumber: Int
    var startDate: Date
    var endDate: Date
    var phase: TrainingPhase
    var targetDistanceKm: Double

    var plan: TrainingPlan?

    @Relationship(deleteRule: .cascade, inverse: \ScheduledWorkout.week)
    var workouts: [ScheduledWorkout] = []

    // MARK: Computed

    var isCompleted: Bool {
        let runWorkouts = workouts.filter { $0.workoutType != .rest }
        guard !runWorkouts.isEmpty else { return false }
        return runWorkouts.allSatisfy(\.isCompleted)
    }

    var completedDistanceKm: Double {
        workouts
            .compactMap(\.completedWorkout)
            .reduce(0) { $0 + $1.distanceMeters / 1_000 }
    }

    init(
        weekNumber: Int,
        startDate: Date,
        phase: TrainingPhase,
        targetDistanceKm: Double
    ) {
        self.id = UUID()
        self.weekNumber = weekNumber
        self.startDate = startDate
        self.endDate = startDate.adding(days: 6)
        self.phase = phase
        self.targetDistanceKm = targetDistanceKm
    }
}
