import Foundation

// MARK: - Editing a logged set

extension StrengthProgression {

    /// The weight to show in a finished set's editor, in the runner's unit: the stored
    /// kilograms, or a number read from an older free-text weight. Nil when there's none.
    public static func editableWeight(of set: CompletedStrengthSet, unit: UnitPreference) -> Double? {
        let kilograms = set.weightKilograms ?? legacyWeightKilograms(from: set.actualWeight, unit: unit)
        return kilograms.map { (displayValue($0, unit: unit) * 10).rounded() / 10 }
    }

    /// `set` with its reps and weight corrected after the session.
    ///
    /// The weight is entered in the runner's unit and stored in kilograms, with the text
    /// copy older app versions read, as a live set is. Clearing the weight (nil or 0)
    /// removes it; a free-text note with no number in it ("Light", "Red band") is kept,
    /// because the editor never showed it as a weight to clear.
    public static func edited(
        _ set: CompletedStrengthSet,
        reps: Int,
        displayWeight: Double?,
        unit: UnitPreference
    ) -> CompletedStrengthSet {
        var result = set
        result.completedReps = max(0, reps)
        if let displayWeight, displayWeight > 0 {
            let kilograms = kilograms(fromDisplay: displayWeight, unit: unit)
            result.weightKilograms = kilograms
            result.actualWeight = weightText(kilograms, unit: unit)
        } else {
            let wasNumber = set.weightKilograms != nil
                || legacyWeightKilograms(from: set.actualWeight, unit: unit) != nil
            result.weightKilograms = nil
            result.actualWeight = wasNumber ? nil : set.actualWeight
        }
        return result
    }
}
