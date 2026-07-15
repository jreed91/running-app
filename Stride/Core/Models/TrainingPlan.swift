import Foundation
import SwiftData

@Model
final class TrainingPlan {
    #Index<TrainingPlan>([\.id], [\.createdAt], [\.isActive], [\.startDate])

    var id: UUID = UUID()
    /// Raw-backed storage for `targetRace` to keep CloudKit fields primitive.
    var targetRaceRaw: String = RaceType.fiveK.rawValue
    /// Absorbs the old CloudKit `targetRace` field so migration can recover it.
    @Attribute(originalName: "targetRace")
    var targetRaceLegacy: String? = nil
    var goalTimeSeconds: Double = 0
    /// User-defined goal distance in meters when `targetRace == .custom`; nil otherwise.
    var customDistanceMeters: Double?
    var raceName: String?
    var raceDate: Date?
    var startDate: Date = Date()
    var endDate: Date = Date()
    var isActive: Bool = false
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \TrainingWeek.plan)
    var weeks: [TrainingWeek]? = []

    // MARK: Computed

    var totalWeeks: Int { (weeks ?? []).count }

    var currentWeek: TrainingWeek? {
        // Compare on day boundaries. `endDate` is stored as the last day at 00:00
        // (see `TrainingWeek.init`), so a raw `endDate >= now` comparison excludes the
        // entire final day of every week — most visibly Sunday, the long-run day.
        let today = Date().startOfDay
        return (weeks ?? []).first {
            $0.startDate.startOfDay <= today && $0.endDate.startOfDay >= today
        }
    }

    /// 0.0 – 1.0 based on completed non-rest workouts.
    var progress: Double {
        let allWeeks = weeks ?? []
        guard !allWeeks.isEmpty else { return 0 }
        let completed = allWeeks.filter(\.isCompleted).count
        return Double(completed) / Double(allWeeks.count)
    }

    /// True when at least one non-rest workout in this plan was completed. Such plans
    /// carry real history (the "Past Plans" list, `PlanSummaryCard`) and must be preserved
    /// — deactivated, not deleted — when a new plan supersedes them.
    var hasLoggedProgress: Bool {
        (weeks ?? []).contains { week in
            (week.workouts ?? []).contains { $0.isCompleted && $0.workoutType != .rest }
        }
    }

    init(
        targetRace: RaceType,
        goalTimeSeconds: Double,
        customDistanceMeters: Double? = nil,
        raceName: String? = nil,
        raceDate: Date? = nil,
        startDate: Date,
        endDate: Date
    ) {
        self.id = UUID()
        self.targetRaceRaw = targetRace.rawValue
        self.goalTimeSeconds = goalTimeSeconds
        self.customDistanceMeters = customDistanceMeters
        self.raceName = raceName
        self.raceDate = raceDate
        self.startDate = startDate
        self.endDate = endDate
        self.isActive = true
        self.createdAt = Date()
    }

    var targetRace: RaceType {
        get { RaceType(rawValue: targetRaceRaw) ?? .fiveK }
        set { targetRaceRaw = newValue.rawValue }
    }

    /// The goal race distance in meters, honoring a user-defined custom distance.
    var effectiveRaceDistanceMeters: Double {
        if targetRace.usesCustomDistance, let custom = customDistanceMeters, custom > 0 {
            return custom
        }
        return targetRace.distanceMeters
    }
}
