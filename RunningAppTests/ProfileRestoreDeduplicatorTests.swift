import Foundation
import SwiftData
import Testing
@testable import RunningApp

@MainActor
struct ProfileRestoreDeduplicatorTests {

    @Test("Newest updated profile wins restore selection")
    func newestUpdatedProfileWins() {
        let stale = makeProfile(
            name: "Stale",
            goalRace: .fiveK,
            gender: .preferNotToShare,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let current = makeProfile(
            name: "Current",
            goalRace: .maintainFitness,
            gender: .female,
            createdAt: Date(timeIntervalSinceReferenceDate: 150),
            updatedAt: Date(timeIntervalSinceReferenceDate: 300)
        )

        let winner = ProfileRestoreDeduplicator.preferredProfile(from: [stale, current])

        #expect(winner?.persistentModelID == current.persistentModelID)
        #expect(winner?.goalRace == .maintainFitness)
        #expect(winner?.gender == .female)
    }

    @Test("Updated-at ties prefer the newest created profile")
    func updatedAtTieUsesNewestCreatedAt() {
        let older = makeProfile(
            name: "Older",
            goalRace: .fiveK,
            gender: .preferNotToShare,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 300)
        )
        let newer = makeProfile(
            name: "Newer",
            goalRace: .maintainFitness,
            gender: .male,
            createdAt: Date(timeIntervalSinceReferenceDate: 150),
            updatedAt: Date(timeIntervalSinceReferenceDate: 300)
        )

        let winner = ProfileRestoreDeduplicator.preferredProfile(from: [older, newer])

        #expect(winner?.persistentModelID == newer.persistentModelID)
    }

    @Test("Single profile remains unchanged during restore selection")
    func singleProfileRemainsUnchanged() {
        let profile = makeProfile(
            name: "Only",
            goalRace: .halfMarathon,
            gender: .female,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        let winner = ProfileRestoreDeduplicator.preferredProfile(from: [profile])

        #expect(winner?.persistentModelID == profile.persistentModelID)
        #expect(winner?.goalRace == .halfMarathon)
        #expect(winner?.gender == .female)
    }

    @Test("Dedup removes stale restored profiles and keeps the latest values")
    func deduplicateLeavesExactlyOneProfile() throws {
        let container = AppContainer.preview()
        let context = container.modelContainer.mainContext

        let stale = makeProfile(
            name: "Stale",
            goalRace: .fiveK,
            gender: .preferNotToShare,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let current = makeProfile(
            name: "Current",
            goalRace: .maintainFitness,
            gender: .female,
            createdAt: Date(timeIntervalSinceReferenceDate: 150),
            updatedAt: Date(timeIntervalSinceReferenceDate: 300)
        )

        context.insert(stale)
        context.insert(current)
        try context.save()

        try ProfileRestoreDeduplicator.deduplicate([stale, current], in: context)

        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        let remaining = try #require(profiles.first)
        #expect(profiles.count == 1)
        #expect(remaining.goalRace == .maintainFitness)
        #expect(remaining.gender == .female)
        #expect(remaining.name == "Current")
    }

    @Test("Goal race raw values decode maintain fitness and unknown values fall back to 5K")
    func goalRaceRawValueCompatibility() {
        let profile = makeProfile(
            name: "Compatibility",
            goalRace: .fiveK,
            gender: .preferNotToShare,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        profile.goalRaceRaw = RaceType.maintainFitness.rawValue
        #expect(profile.goalRace == .maintainFitness)

        profile.goalRaceRaw = "legacy_unknown_goal"
        #expect(profile.goalRace == .fiveK)
    }

    private func makeProfile(
        name: String,
        goalRace: RaceType,
        gender: Gender,
        createdAt: Date,
        updatedAt: Date
    ) -> UserProfile {
        let profile = UserProfile(
            name: name,
            goalRace: goalRace,
            goalFinishTime: 0,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate,
            gender: gender
        )
        profile.createdAt = createdAt
        profile.updatedAt = updatedAt
        return profile
    }
}
