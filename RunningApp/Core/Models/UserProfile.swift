import Foundation
import SwiftData

@Model
final class UserProfile {
    #Index<UserProfile>([\.id], [\.createdAt], [\.updatedAt])

    var id: UUID = UUID()
    var name: String = ""
    var goalRace: RaceType = RaceType.fiveK
    var goalFinishTime: TimeInterval = 0      // seconds
    var weeklyRunDays: Int = 3
    var fitnessLevel: FitnessLevel = FitnessLevel.beginner
    var gender: Gender = Gender.preferNotToShare
    var currentEstimated5KTimeSeconds: Double?
    /// JSON-encoded `[Int]` backing store for preferred run weekdays.
    /// Access via the `preferredRunDayIndices` extension property — never persist `[Int]` directly.
    var preferredRunDayIndicesData: Data?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        name: String,
        goalRace: RaceType,
        goalFinishTime: TimeInterval,
        weeklyRunDays: Int,
        fitnessLevel: FitnessLevel,
        gender: Gender = .preferNotToShare,
        currentEstimated5KTimeSeconds: Double? = nil,
        preferredRunDayIndices: [Int] = []
    ) {
        self.id = UUID()
        self.name = name
        self.goalRace = goalRace
        self.goalFinishTime = goalFinishTime
        self.weeklyRunDays = weeklyRunDays
        self.fitnessLevel = fitnessLevel
        self.gender = gender
        self.currentEstimated5KTimeSeconds = currentEstimated5KTimeSeconds
        self.preferredRunDayIndicesData = preferredRunDayIndices.isEmpty
            ? nil
            : .encoded(preferredRunDayIndices)
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Computed helpers
// Defined in an extension so @Model does not treat these as persistent attributes.

extension UserProfile {
    /// Weekday indices (0 = Monday … 6 = Sunday) the user prefers to run.
    /// Empty means "spread evenly based on weeklyRunDays".
    var preferredRunDayIndices: [Int] {
        get { preferredRunDayIndicesData?.decode([Int].self) ?? [] }
        set { preferredRunDayIndicesData = newValue.isEmpty ? nil : .encoded(newValue) }
    }
}
