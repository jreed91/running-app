import Foundation
import Testing
@testable import StrideCore

/// Covers the runner's own strength amount: sessions a week, where they go, and how a
/// chosen session length trims the session.
struct StrengthPreferencesTests {

    @Test("Without a choice the plan's long-standing rule holds")
    func automaticMatchesTheOldRule() {
        let auto = StrengthPreferences()
        #expect(auto.strengthDays(phase: .base, focus: .runningSpecific, isBeginner: false) == 2)
        #expect(auto.strengthDays(phase: .build, focus: .generalStrength, isBeginner: false) == 1)
        #expect(auto.strengthDays(phase: .peak, focus: .runningSpecific, isBeginner: false) == 1)
        #expect(auto.strengthDays(phase: .taper, focus: .runningSpecific, isBeginner: true) == 0)
        #expect(auto.strengthDays(phase: .taper, focus: .runningSpecific, isBeginner: false) == 1)
    }

    @Test("A chosen number wins, clamped to 0–3, and a taper still gets at most one")
    func chosenNumber() {
        #expect(StrengthPreferences(daysPerWeek: 3).strengthDays(phase: .build, focus: .generalStrength, isBeginner: false) == 3)
        #expect(StrengthPreferences(daysPerWeek: 0).strengthDays(phase: .base, focus: .runningSpecific, isBeginner: false) == 0)
        #expect(StrengthPreferences(daysPerWeek: 9).strengthDays(phase: .peak, focus: .runningSpecific, isBeginner: false) == 3)
        #expect(StrengthPreferences(daysPerWeek: 3).strengthDays(phase: .taper, focus: .runningSpecific, isBeginner: false) == 1)
    }

    @Test("Strength days avoid run days, the days around hard sessions, and race eve")
    func dayPlacement() {
        // Runs Tue (1), Thu (3, tempo), Sun (6, long run).
        let days = StrengthPreferences.strengthDayOffsets(
            count: 3, occupied: [1, 3, 6], hardDays: [3, 6], raceDay: nil
        )
        // Mon (0) is free and next to nothing hard; Wed, Fri, Sat sit beside a hard day.
        #expect(days == [0])

        let easyWeek = StrengthPreferences.strengthDayOffsets(
            count: 3, occupied: [1, 3], hardDays: [], raceDay: nil
        )
        #expect(easyWeek == [0, 2, 4])

        let raceWeek = StrengthPreferences.strengthDayOffsets(
            count: 2, occupied: [], hardDays: [], raceDay: 3
        )
        #expect(raceWeek == [0, 1])
        #expect(StrengthPreferences.strengthDayOffsets(count: 0, occupied: [], hardDays: [], raceDay: nil).isEmpty)
    }

    @Test("A shorter session drops exercises from the end, keeping at least three")
    func sessionLength() {
        let full = StrengthLibrary.plan(for: [.dumbbells], focus: .runningSpecific, phase: .base)
        let medium = StrengthLibrary.plan(for: [.dumbbells], focus: .runningSpecific, phase: .base, minutes: 35)
        let short = StrengthLibrary.plan(for: [.dumbbells], focus: .runningSpecific, phase: .build, minutes: 25)

        #expect(medium.exercises.count < full.exercises.count)
        #expect(medium.estimatedDurationMinutes <= 35)
        #expect(Array(full.exercises.prefix(medium.exercises.count)) == medium.exercises)
        #expect(short.exercises.count == StrengthLibrary.minimumExercisesForLength)
        #expect(StrengthLibrary.plan(for: [.dumbbells], focus: .runningSpecific, phase: .base, minutes: nil) == full)
    }

    @Test("Preferences round-trip through defaults, and nothing stored means automatic")
    func storage() throws {
        let defaults = try #require(UserDefaults(suiteName: "StrengthPreferencesTests-\(UUID().uuidString)"))
        #expect(StrengthPreferences.load(from: defaults) == StrengthPreferences())
        let chosen = StrengthPreferences(daysPerWeek: 3, sessionMinutes: 25)
        chosen.save(to: defaults)
        #expect(StrengthPreferences.load(from: defaults) == chosen)
    }

    // MARK: Excluded exercises

    @Test("An excluded exercise is left out and the next in line takes its place")
    func excludedExercisesAreReplaced() {
        let full = StrengthLibrary.plan(for: [.dumbbells, .resistanceBands], focus: .runningSpecific, phase: .build)
        let dropped = full.exercises[1].name
        let without = StrengthLibrary.plan(
            for: [.dumbbells, .resistanceBands], focus: .runningSpecific, phase: .build,
            excluding: [dropped]
        )
        #expect(!without.exercises.contains { $0.name == dropped })
        #expect(without.exercises.count == full.exercises.count)
    }

    @Test("Swap never offers an excluded exercise")
    func swapSkipsExcluded() throws {
        let squat = try #require(StrengthLibrary.catalog.first { $0.name == "DB Goblet Squat" })
        let offered = StrengthLibrary.alternatives(to: squat, equipment: [.dumbbells, .kettlebell])
        let first = try #require(offered.first)
        let filtered = StrengthLibrary.alternatives(to: squat, equipment: [.dumbbells, .kettlebell], excluding: [first.name])
        #expect(!filtered.contains { $0.name == first.name })
    }

    @Test("Excluding is idempotent, putting back removes it, and older saved preferences still load")
    func excludeAndInclude() throws {
        var preferences = StrengthPreferences()
        preferences.exclude("Deadlift")
        preferences.exclude("Deadlift")
        preferences.exclude("Good Morning")
        #expect(preferences.excludedExercises == ["Deadlift", "Good Morning"])
        preferences.include("Deadlift")
        #expect(preferences.excluded == ["Good Morning"])

        let older = Data(#"{"daysPerWeek":2}"#.utf8)
        let decoded = try JSONDecoder().decode(StrengthPreferences.self, from: older)
        #expect(decoded == StrengthPreferences(daysPerWeek: 2))
    }

    // MARK: Standing swaps

    @Test("A standing swap puts the stand-in in with the original's sets and reps")
    func standingSwap() throws {
        let full = StrengthLibrary.plan(for: [.dumbbells], focus: .generalStrength, phase: .build)
        let original = try #require(full.exercises.first { $0.equipment == .dumbbells })
        let standIn = try #require(StrengthLibrary.alternatives(to: original, equipment: [.dumbbells]).first)

        let swapped = StrengthLibrary.plan(
            for: [.dumbbells], focus: .generalStrength, phase: .build,
            preferences: StrengthPreferences(replacements: [original.name: standIn.name])
        )
        #expect(!swapped.exercises.contains { $0.name == original.name })
        let placed = try #require(swapped.exercises.first { $0.name == standIn.name })
        #expect(placed.sets == original.sets)
    }

    @Test("A standing swap needing equipment the runner doesn't have is ignored")
    func standingSwapNeedsEquipment() {
        let plan = StrengthLibrary.plan(
            for: [.bodyweight], focus: .runningSpecific, phase: .base,
            preferences: StrengthPreferences(replacements: ["Glute Bridge": "Barbell Hip Thrust"])
        )
        #expect(plan.exercises.contains { $0.name == "Glute Bridge" })
        #expect(!plan.exercises.contains { $0.name == "Barbell Hip Thrust" })
    }

    @Test("Swapping again follows the original; swapping back drops the rule")
    func replaceChains() {
        var preferences = StrengthPreferences()
        preferences.replace("Back Squat", with: "DB Goblet Squat")
        preferences.replace("DB Goblet Squat", with: "KB Goblet Squat")
        #expect(preferences.replacements == ["Back Squat": "KB Goblet Squat"])
        preferences.replace("KB Goblet Squat", with: "Back Squat")
        #expect(preferences.replacements.isEmpty)
    }

    // MARK: Editing a session

    @Test("Exercises to add use owned equipment and skip what's in the session or excluded")
    func addableExercises() {
        let session = StrengthLibrary.plan(for: [.dumbbells], focus: .runningSpecific, phase: .base).exercises
        let addable = StrengthLibrary.addable(to: session, equipment: [.dumbbells], excluding: ["Plank"])
        #expect(!addable.isEmpty)
        #expect(addable.allSatisfy { $0.equipment == .dumbbells || $0.equipment == .bodyweight })
        #expect(!addable.contains { candidate in session.contains { $0.name == candidate.name } })
        #expect(!addable.contains { $0.name == "Plank" })
        #expect(addable.map(\.name) == addable.map(\.name).sorted())
    }

    @Test("An added exercise takes the session's sets and reps; a hold keeps its time")
    func addedMatchesTheSession() throws {
        let session = StrengthLibrary.plan(for: [.dumbbells], focus: .generalStrength, phase: .peak).exercises
        let template = try #require(session.first { $0.durationSeconds == nil })
        let row = try #require(StrengthLibrary.catalog.first { $0.name == "DB Bent-Over Row" })
        let added = StrengthLibrary.added(row, to: session)
        #expect(added.sets == template.sets)
        #expect(added.reps == template.reps)

        let plank = try #require(StrengthLibrary.catalog.first { $0.name == "Plank" })
        #expect(StrengthLibrary.added(plank, to: session).durationSeconds == plank.durationSeconds)
    }
}
