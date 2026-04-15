import Foundation
import SwiftData

@Model
final class TrainingWeek {
    var id: UUID = UUID()
    var weekNumber: Int = 0
    var startDate: Date = Date()
    var endDate: Date = Date()
    var phase: TrainingPhase = TrainingPhase.base
    var targetDistanceKm: Double = 0

    var plan: TrainingPlan?

    @Relationship(deleteRule: .cascade, inverse: \ScheduledWorkout.week)
    var workouts: [ScheduledWorkout]? = []

    // MARK: Computed

    var isCompleted: Bool {
        let runWorkouts = (workouts ?? []).filter { $0.workoutType != .rest }
        guard !runWorkouts.isEmpty else { return false }
        return runWorkouts.allSatisfy(\.isCompleted)
    }

    var completedDistanceKm: Double {
        (workouts ?? [])
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
