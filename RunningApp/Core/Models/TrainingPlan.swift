import Foundation
import SwiftData

@Model
final class TrainingPlan {
    var id: UUID
    var targetRace: RaceType
    var goalTimeSeconds: Double
    var startDate: Date
    var endDate: Date
    var isActive: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \TrainingWeek.plan)
    var weeks: [TrainingWeek] = []

    // MARK: Computed

    var totalWeeks: Int { weeks.count }

    var currentWeek: TrainingWeek? {
        let today = Date()
        return weeks.first { $0.startDate <= today && $0.endDate >= today }
    }

    /// 0.0 – 1.0 based on completed non-rest workouts.
    var progress: Double {
        guard !weeks.isEmpty else { return 0 }
        let completed = weeks.filter(\.isCompleted).count
        return Double(completed) / Double(weeks.count)
    }

    init(
        targetRace: RaceType,
        goalTimeSeconds: Double,
        startDate: Date,
        endDate: Date
    ) {
        self.id = UUID()
        self.targetRace = targetRace
        self.goalTimeSeconds = goalTimeSeconds
        self.startDate = startDate
        self.endDate = endDate
        self.isActive = true
        self.createdAt = Date()
    }
}
