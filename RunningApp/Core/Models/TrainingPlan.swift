import Foundation
import SwiftData

@Model
final class TrainingPlan {
    var id: UUID = UUID()
    var targetRace: RaceType = RaceType.fiveK
    var goalTimeSeconds: Double = 0
    var startDate: Date = Date()
    var endDate: Date = Date()
    var isActive: Bool = false
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \TrainingWeek.plan)
    var weeks: [TrainingWeek]? = []

    // MARK: Computed

    var totalWeeks: Int { (weeks ?? []).count }

    var currentWeek: TrainingWeek? {
        let today = Date()
        return (weeks ?? []).first { $0.startDate <= today && $0.endDate >= today }
    }

    /// 0.0 – 1.0 based on completed non-rest workouts.
    var progress: Double {
        let allWeeks = weeks ?? []
        guard !allWeeks.isEmpty else { return 0 }
        let completed = allWeeks.filter(\.isCompleted).count
        return Double(completed) / Double(allWeeks.count)
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
