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
    /// JSON-encoded `[Int]` backing store for preferred run weekdays.
    /// Access via the `preferredRunDayIndices` extension property — never persist `[Int]` directly.
    var preferredRunDayIndicesData: Data?
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        goalRace: RaceType,
        goalFinishTime: TimeInterval,
        weeklyRunDays: Int,
        fitnessLevel: FitnessLevel,
        currentEstimated5KTimeSeconds: Double? = nil,
        preferredRunDayIndices: [Int] = []
    ) {
        self.id = UUID()
        self.name = name
        self.goalRace = goalRace
        self.goalFinishTime = goalFinishTime
        self.weeklyRunDays = weeklyRunDays
        self.fitnessLevel = fitnessLevel
        self.currentEstimated5KTimeSeconds = currentEstimated5KTimeSeconds
        self.preferredRunDayIndicesData = preferredRunDayIndices.isEmpty
            ? nil
            : try? JSONEncoder().encode(preferredRunDayIndices)
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
        get {
            guard let data = preferredRunDayIndicesData else { return [] }
            return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
        }
        set {
            preferredRunDayIndicesData = newValue.isEmpty
                ? nil
                : try? JSONEncoder().encode(newValue)
        }
    }
}
