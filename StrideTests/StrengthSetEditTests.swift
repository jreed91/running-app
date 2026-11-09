import Foundation
import Testing
@testable import Stride

/// Covers correcting a finished session's sets: weights entered in the runner's unit,
/// stored in kilograms, with older free-text weights read and kept sensibly.
struct StrengthSetEditTests {

    private func set(reps: Int = 8, text: String? = nil, kilograms: Double? = nil) -> CompletedStrengthSet {
        CompletedStrengthSet(
            exerciseIndex: 0, setIndex: 0, completedReps: reps,
            actualWeight: text, skipped: false,
            exerciseName: "Back Squat", weightKilograms: kilograms
        )
    }

    @Test("A new weight is stored in kilograms with its text copy")
    func storesKilograms() {
        let edited = StrengthProgression.edited(set(kilograms: 40), reps: 10, displayWeight: 135, unit: .imperial)
        #expect(edited.completedReps == 10)
        #expect(abs((edited.weightKilograms ?? 0) - 61.235) < 0.01)
        #expect(edited.actualWeight == StrengthProgression.weightText(edited.weightKilograms ?? 0, unit: .imperial))
        #expect(edited.exerciseName == "Back Squat")
    }

    @Test("Clearing a numeric weight removes it, a note without a number stays")
    func clearing() {
        let numeric = StrengthProgression.edited(set(text: "40 kg", kilograms: 40), reps: 8, displayWeight: nil, unit: .metric)
        #expect(numeric.weightKilograms == nil)
        #expect(numeric.actualWeight == nil)

        let legacy = StrengthProgression.edited(set(text: "40 kg"), reps: 8, displayWeight: 0, unit: .metric)
        #expect(legacy.actualWeight == nil)

        let note = StrengthProgression.edited(set(text: "Red band"), reps: 12, displayWeight: nil, unit: .metric)
        #expect(note.actualWeight == "Red band")
        #expect(note.completedReps == 12)
    }

    @Test("Reps never go below zero")
    func repsFloor() {
        #expect(StrengthProgression.edited(set(), reps: -3, displayWeight: nil, unit: .metric).completedReps == 0)
    }

    @Test("The editor starts from stored kilograms, or a number in older text")
    func editableWeight() {
        #expect(StrengthProgression.editableWeight(of: set(kilograms: 60), unit: .metric) == 60)
        #expect(StrengthProgression.editableWeight(of: set(text: "40 kg"), unit: .metric) == 40)
        #expect(StrengthProgression.editableWeight(of: set(text: "Light"), unit: .metric) == nil)
        #expect(StrengthProgression.editableWeight(of: set(kilograms: 20), unit: .imperial) == 44.1)
    }
}
