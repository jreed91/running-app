import Foundation
import Testing
@testable import Stride

/// Covers `StrengthProgression`: what was lifted last time, and what to lift next.
/// A wrong suggestion is a lifter loading a bar they can't move, so the steps, the
/// rounding and the backing-off rules are pinned here.
struct StrengthProgressionTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    private func set(_ name: String, _ reps: Int, _ kg: Double?, skipped: Bool = false) -> LoggedStrengthSet {
        LoggedStrengthSet(exerciseName: name, reps: reps, weightKilograms: kg, skipped: skipped)
    }

    private func exercise(
        _ name: String,
        sets: Int = 3,
        reps: Int = 10,
        equipment: StrengthEquipment? = .dumbbells,
        seconds: Int? = nil
    ) -> StrengthExercise {
        StrengthExercise(
            name: name,
            sets: sets,
            reps: reps,
            durationSeconds: seconds,
            targetWeight: nil,
            notes: nil,
            muscleGroups: [],
            equipment: equipment
        )
    }

    private func performance(_ sets: [LoggedStrengthSet], daysAgo days: Double = 3) -> ExercisePerformance {
        ExercisePerformance(date: daysAgo(days), sets: sets)
    }

    // MARK: History

    @Test func lastPerformanceIsTheNewestSessionWithWorkingSets() throws {
        let sessions = [
            StrengthSessionLog(date: daysAgo(10), sets: [set("Squat", 10, 40)]),
            StrengthSessionLog(date: daysAgo(3), sets: [set("Squat", 0, nil, skipped: true), set("Row", 10, 20)]),
            StrengthSessionLog(date: daysAgo(6), sets: [set("squat ", 8, 45)]),
        ]
        let last = try #require(StrengthProgression.lastPerformance(of: "Squat", in: sessions))
        // The session three days ago only skipped it, so it doesn't count.
        #expect(last.date == daysAgo(6))
        #expect(last.topWeightKilograms == 45)
    }

    @Test func lastPerformanceIgnoresTheSessionBeingLogged() throws {
        let sessions = [
            StrengthSessionLog(date: daysAgo(7), sets: [set("Row", 10, 20)]),
            StrengthSessionLog(date: now, sets: [set("Row", 10, 22)]),
        ]
        let last = try #require(StrengthProgression.lastPerformance(of: "Row", in: sessions, before: now))
        #expect(last.topWeightKilograms == 20)
        #expect(StrengthProgression.lastPerformance(of: "Deadlift", in: sessions) == nil)
    }

    @Test func topSetsAreTheOnesAtTheHeaviestLoad() {
        let perf = performance([set("Row", 12, 18), set("Row", 10, 20), set("Row", 9, 20)])
        #expect(perf.topWeightKilograms == 20)
        #expect(perf.topSets.map(\.reps) == [10, 9])
    }

    // MARK: Double progression

    @Test func everySetAtTargetAddsAStep() {
        let last = performance([set("Goblet Squat", 10, 20), set("Goblet Squat", 10, 20), set("Goblet Squat", 11, 20)])
        let next = StrengthProgression.suggestion(for: exercise("Goblet Squat"), last: last, unit: .metric, now: now)
        #expect(next.reason == .increase)
        #expect(next.weightKilograms == 22)
        #expect(next.reps == 10)
    }

    @Test func barbellStepsByTwoAndAHalfKilos() {
        let last = performance(Array(repeating: set("Back Squat", 8, 60), count: 3))
        let next = StrengthProgression.suggestion(
            for: exercise("Back Squat", reps: 8, equipment: .barbell), last: last, unit: .metric, now: now
        )
        #expect(next.weightKilograms == 62.5)
    }

    @Test func kettlebellStepsByFourKilos() {
        let last = performance(Array(repeating: set("KB Goblet Squat", 10, 16), count: 3))
        let next = StrengthProgression.suggestion(
            for: exercise("KB Goblet Squat", equipment: .kettlebell), last: last, unit: .metric, now: now
        )
        #expect(next.weightKilograms == 20)
    }

    @Test func poundsStepByFiveAndStayRound() throws {
        // 95 lb logged, all reps made: 100 lb next, not 99.99.
        let last = performance(Array(repeating: set("Bench Press", 8, 95 * StrengthProgression.kilogramsPerPound), count: 3))
        let next = StrengthProgression.suggestion(
            for: exercise("Bench Press", reps: 8, equipment: .barbell), last: last, unit: .imperial, now: now
        )
        let kg = try #require(next.weightKilograms)
        #expect(abs(StrengthProgression.displayValue(kg, unit: .imperial) - 100) < 0.0001)
        #expect(StrengthProgression.weightText(kg, unit: .imperial) == "100 lb")
    }

    @Test func aMissedSetHoldsTheLoad() {
        let last = performance([set("Row", 10, 20), set("Row", 10, 20), set("Row", 8, 20)])
        let next = StrengthProgression.suggestion(for: exercise("Row"), last: last, unit: .metric, now: now)
        #expect(next.reason == .repeatLoad)
        #expect(next.weightKilograms == 20)
    }

    @Test func fewerSetsThanPlannedHoldsTheLoad() {
        // Two good sets of three is not "every set".
        let last = performance([set("Row", 10, 20), set("Row", 10, 20)])
        let next = StrengthProgression.suggestion(for: exercise("Row", sets: 3), last: last, unit: .metric, now: now)
        #expect(next.reason == .repeatLoad)
    }

    @Test func mostSetsWellShortTakesAStepOff() {
        let last = performance([set("Row", 7, 24), set("Row", 6, 24), set("Row", 9, 24)])
        let next = StrengthProgression.suggestion(for: exercise("Row"), last: last, unit: .metric, now: now)
        #expect(next.reason == .decrease)
        #expect(next.weightKilograms == 22)
    }

    @Test func neverSuggestsLessThanOneStep() {
        let last = performance([set("Row", 3, 2), set("Row", 3, 2), set("Row", 3, 2)])
        let next = StrengthProgression.suggestion(for: exercise("Row"), last: last, unit: .metric, now: now)
        #expect(next.weightKilograms == 2)
    }

    @Test func aLongGapStartsOneStepBack() {
        let last = performance(Array(repeating: set("Deadlift", 5, 100), count: 3), daysAgo: 60)
        let next = StrengthProgression.suggestion(
            for: exercise("Deadlift", reps: 5, equipment: .barbell), last: last, unit: .metric, now: now
        )
        #expect(next.reason == .returning)
        #expect(next.weightKilograms == 97.5)
    }

    @Test func aPhaseWithFewerRepsCountsTheOldRepsAsMade() {
        // Did 12s in base; build asks for 10s at a heavier load.
        let last = performance(Array(repeating: set("Row", 12, 20), count: 3))
        let next = StrengthProgression.suggestion(for: exercise("Row", reps: 10), last: last, unit: .metric, now: now)
        #expect(next.reason == .increase)
        #expect(next.reps == 10)
    }

    // MARK: When there is nothing to move

    @Test func firstTimeHasNoNumber() {
        let next = StrengthProgression.suggestion(for: exercise("Row"), last: nil, unit: .metric, now: now)
        #expect(next == LoadSuggestion(weightKilograms: nil, reps: 10, reason: .firstTime))
    }

    @Test func lastTimeWithoutALoadIsAFirstTime() {
        let last = performance([set("Row", 10, nil)])
        let next = StrengthProgression.suggestion(for: exercise("Row"), last: last, unit: .metric, now: now)
        #expect(next.reason == .firstTime)
    }

    @Test func bodyweightBandsAndBarAreUnloaded() {
        for equipment in [StrengthEquipment.bodyweight, .resistanceBands, .pullUpBar] {
            let next = StrengthProgression.suggestion(
                for: exercise("Move", equipment: equipment),
                last: performance([set("Move", 10, 10)]),
                unit: .metric,
                now: now
            )
            #expect(next.reason == .unloaded)
            #expect(next.weightKilograms == nil)
        }
    }

    @Test func timedHoldsAreUnloaded() {
        let next = StrengthProgression.suggestion(
            for: exercise("Farmer Hold", seconds: 30), last: nil, unit: .metric, now: now
        )
        #expect(next.reason == .unloaded)
    }

    @Test func amrapHoldsTheLoad() {
        let last = performance([set("Swing", 30, 16)])
        let next = StrengthProgression.suggestion(
            for: exercise("Swing", reps: 0, equipment: .kettlebell), last: last, unit: .metric, now: now
        )
        #expect(next == LoadSuggestion(weightKilograms: 16, reps: 0, reason: .repeatLoad))
    }

    // MARK: Equipment of older plans

    @Test func olderPlansFindTheirEquipmentByName() {
        #expect(StrengthProgression.equipment(for: exercise("DB Goblet Squat", equipment: nil)) == .dumbbells)
        #expect(StrengthProgression.equipment(for: exercise("Back Squat", equipment: nil)) == .barbell)
        #expect(StrengthProgression.equipment(for: exercise("Kettlebell Swing", equipment: nil)) == .kettlebell)
        #expect(StrengthProgression.equipment(for: exercise("Glute Bridge", equipment: nil)) == .bodyweight)
        #expect(StrengthProgression.equipment(for: exercise("Pull-Up", equipment: nil)) == .pullUpBar)
        #expect(StrengthProgression.equipment(for: exercise("Mystery Move", equipment: nil)) == nil)
    }

    @Test func libraryStampsEquipmentOnEveryExercise() {
        let all = StrengthLibrary.exercises(
            for: StrengthEquipment.allCases, focus: .generalStrength, phase: .build
        ) + StrengthLibrary.exercises(for: StrengthEquipment.allCases, focus: .runningSpecific, phase: .base)
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { $0.equipment != nil })
    }

    // MARK: Numbers

    @Test func epleyEstimate() {
        #expect(StrengthProgression.estimatedOneRepMax(weightKilograms: 100, reps: 1) == 100)
        #expect(StrengthProgression.estimatedOneRepMax(weightKilograms: 100, reps: 10) == 100 * (1 + 10.0 / 30))
        #expect(StrengthProgression.estimatedOneRepMax(weightKilograms: 100, reps: 15) == nil)
        #expect(StrengthProgression.estimatedOneRepMax(weightKilograms: 0, reps: 5) == nil)
    }

    @Test func weightTextDropsTrailingZero() {
        #expect(StrengthProgression.weightText(42.5, unit: .metric) == "42.5 kg")
        #expect(StrengthProgression.weightText(40, unit: .metric) == "40 kg")
    }

    @Test func legacyTextWeights() throws {
        #expect(StrengthProgression.legacyWeightKilograms(from: "40 kg", unit: .imperial) == 40)
        #expect(StrengthProgression.legacyWeightKilograms(from: "12,5kg", unit: .imperial) == 12.5)
        let pounds = try #require(StrengthProgression.legacyWeightKilograms(from: "90 lb", unit: .metric))
        #expect(abs(pounds - 90 * StrengthProgression.kilogramsPerPound) < 0.0001)
        #expect(StrengthProgression.legacyWeightKilograms(from: "20", unit: .metric) == 20)
        let bare = try #require(StrengthProgression.legacyWeightKilograms(from: "20", unit: .imperial))
        #expect(abs(bare - 20 * StrengthProgression.kilogramsPerPound) < 0.0001)
        for text in ["Light", "Bodyweight", "red band", "3x10", "", nil] as [String?] {
            #expect(StrengthProgression.legacyWeightKilograms(from: text, unit: .metric) == nil, "\(String(describing: text))")
        }
    }
}
