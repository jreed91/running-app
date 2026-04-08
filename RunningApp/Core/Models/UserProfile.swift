import Foundation
import SwiftData

@Model
final class UserProfile {
    var id: UUID
    var name: String
    var goalRace: RaceType
    var goalFinishTime: TimeInterval      // seconds
    var weeklyRunDays: Int
    var fitnessLevel: FitnessLevel
    var currentEstimated5KTimeSeconds: Double?
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        goalRace: RaceType,
        goalFinishTime: TimeInterval,
        weeklyRunDays: Int,
        fitnessLevel: FitnessLevel,
        currentEstimated5KTimeSeconds: Double? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.goalRace = goalRace
        self.goalFinishTime = goalFinishTime
        self.weeklyRunDays = weeklyRunDays
        self.fitnessLevel = fitnessLevel
        self.currentEstimated5KTimeSeconds = currentEstimated5KTimeSeconds
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
