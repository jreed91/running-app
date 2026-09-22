import Foundation
import SwiftData

@Model
final class TrainingWeek {
    #Index<TrainingWeek>([\.id], [\.startDate], [\.weekNumber])

    var id: UUID = UUID()
    var weekNumber: Int = 0
    var startDate: Date = Date()
    var endDate: Date = Date()
    /// Raw-backed storage for `phase` to keep CloudKit fields primitive.
    var phaseRaw: String = TrainingPhase.base.rawValue
    /// Absorbs the old CloudKit `phase` field so migration can recover it.
    @Attribute(originalName: "phase")
    var phaseLegacy: String? = nil
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

    /// Running distance only: a cross-training day completed by an imported ride (B8) is
    /// linked through the same `completedWorkout`, and its kilometres are not running ones.
    var completedDistanceKm: Double {
        (workouts ?? [])
            .compactMap(\.completedWorkout)
            .runsOnly
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
        self.phaseRaw = phase.rawValue
        self.targetDistanceKm = targetDistanceKm
    }

    var phase: TrainingPhase {
        get { TrainingPhase(rawValue: phaseRaw) ?? .base }
        set { phaseRaw = newValue.rawValue }
    }
}
