import Foundation
import SwiftData

@Model
final class UserProfile {
    #Index<UserProfile>([\.id], [\.createdAt], [\.updatedAt])

    var id: UUID = UUID()
    var name: String = ""
    /// Raw-backed storage for `goalRace` to keep CloudKit fields primitive.
    var goalRaceRaw: String = RaceType.fiveK.rawValue
    var goalFinishTime: TimeInterval = 0      // seconds
    var weeklyRunDays: Int = 3
    /// Raw-backed storage for `fitnessLevel` to keep CloudKit fields primitive.
    var fitnessLevelRaw: String = FitnessLevel.beginner.rawValue
    /// Raw-backed storage for `gender` to keep CloudKit fields primitive.
    var genderRaw: String = Gender.preferNotToShare.rawValue
    /// Absorbs the old CloudKit `gender` field so migration can recover it.
    @Attribute(originalName: "gender")
    var genderLegacy: String? = nil
    /// Absorbs the old CloudKit `goalRace` field so migration can recover it.
    @Attribute(originalName: "goalRace")
    var goalRaceLegacy: String? = nil
    /// Absorbs the old CloudKit `fitnessLevel` field so migration can recover it.
    @Attribute(originalName: "fitnessLevel")
    var fitnessLevelLegacy: String? = nil
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
        self.goalRaceRaw = goalRace.rawValue
        self.goalFinishTime = goalFinishTime
        self.weeklyRunDays = weeklyRunDays
        self.fitnessLevelRaw = fitnessLevel.rawValue
        self.genderRaw = gender.rawValue
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
    var goalRace: RaceType {
        get { RaceType(rawValue: goalRaceRaw) ?? .fiveK }
        set { goalRaceRaw = newValue.rawValue }
    }

    var fitnessLevel: FitnessLevel {
        get { FitnessLevel(rawValue: fitnessLevelRaw) ?? .beginner }
        set { fitnessLevelRaw = newValue.rawValue }
    }

    var gender: Gender {
        get { Gender(rawValue: genderRaw) ?? .preferNotToShare }
        set { genderRaw = newValue.rawValue }
    }

    /// Weekday indices (0 = Monday … 6 = Sunday) the user prefers to run.
    /// Empty means "spread evenly based on weeklyRunDays".
    var preferredRunDayIndices: [Int] {
        get { preferredRunDayIndicesData?.decode([Int].self) ?? [] }
        set { preferredRunDayIndicesData = newValue.isEmpty ? nil : .encoded(newValue) }
    }
}
