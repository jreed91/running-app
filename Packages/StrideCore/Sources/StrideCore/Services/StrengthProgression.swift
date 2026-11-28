import Foundation

// MARK: - Logged sets as values

/// One logged set, resolved to its exercise's name: the shape ``StrengthProgression`` reads.
///
/// `StrengthWorkout` keeps sets as `CompletedStrengthSet`, which points into a plan by
/// index and, before numbers, held its weight as text. This is the same set with both
/// questions already answered, so the rules below never touch SwiftData.
struct LoggedStrengthSet: Equatable, Sendable {
    let exerciseName: String
    let reps: Int
    let weightKilograms: Double?
    let skipped: Bool
}

/// One finished strength session as values.
struct StrengthSessionLog: Equatable, Sendable {
    let date: Date
    let sets: [LoggedStrengthSet]
    /// How long the session lasted. The only measure a workout from the Watch or another
    /// app has: those come in from Apple Health with no sets.
    var durationSeconds: Double = 0
}

// MARK: - ExercisePerformance

/// How an exercise went the last time it was done: its working sets, skipped ones left out.
struct ExercisePerformance: Equatable, Sendable {
    let date: Date
    let sets: [LoggedStrengthSet]

    /// The heaviest load lifted, or nil when no set carried one.
    var topWeightKilograms: Double? {
        sets.compactMap(\.weightKilograms).max()
    }

    /// The sets done at the top load, or every set when none carried a load.
    var topSets: [LoggedStrengthSet] {
        guard let top = topWeightKilograms else { return sets }
        return sets.filter { $0.weightKilograms == top }
    }

    /// The best Epley estimate across the sets, for the Progress tab's strength trend.
    var estimatedOneRepMaxKilograms: Double? {
        sets.compactMap { set in
            set.weightKilograms.flatMap { StrengthProgression.estimatedOneRepMax(weightKilograms: $0, reps: set.reps) }
        }.max()
    }
}

// MARK: - LoadSuggestion

/// What to lift next time, and why, in the words the session screen shows.
struct LoadSuggestion: Equatable, Sendable {

    enum Reason: Equatable, Sendable {
        /// Never done before: no number to go on, so the plan's description stands.
        case firstTime
        /// Every set at the top load reached the target: one step heavier.
        case increase
        /// Close, but not every set got there: same load, same target.
        case repeatLoad
        /// Most sets fell well short: one step lighter, so the reps come back.
        case decrease
        /// Not done for a long while: one step lighter to come back in.
        case returning
        /// Done with bodyweight or a band, or held for time: no load to change.
        case unloaded
    }

    /// The load to put on the bar or pick up, or nil when there is none to suggest.
    let weightKilograms: Double?
    /// The reps to aim for per set: the plan's, which move with the training phase.
    let reps: Int
    let reason: Reason
}

// MARK: - StrengthProgression

/// Turns what was lifted last time into what to lift this time.
///
/// Double progression, the standard rule for a lifter without a coach: keep the load
/// until every set reaches the target reps, then add the smallest sensible step. Sets
/// that fall well short take a step off instead, and a long gap starts one step back.
/// The plan sets the reps (they change with the phase); this only moves the load.
///
/// Weights are kilograms throughout. Steps are taken in the runner's unit, because that
/// is what the plates and dumbbells in front of them are marked in, and the result is
/// rounded to that step so the screen never suggests 22.68 kg.
enum StrengthProgression {

    /// Reps short of the target that count as falling well short: two short is a hard
    /// last set, three or more on most sets means the load was too heavy.
    static let wellShortReps = 3

    /// A gap longer than this starts one step back.
    static let returningAfterDays = 42

    /// Epley is only fair up to about twelve reps; past that it guesses wildly high.
    static let oneRepMaxRepLimit = 12

    // MARK: History

    /// The most recent session in `sessions` with a working set of `exerciseName`, before
    /// `before` when given (so a session being logged does not answer for itself).
    static func lastPerformance(
        of exerciseName: String,
        in sessions: [StrengthSessionLog],
        before: Date? = nil
    ) -> ExercisePerformance? {
        let key = normalised(exerciseName)
        let candidates = sessions
            .filter { session in before.map { session.date < $0 } ?? true }
            .sorted { $0.date > $1.date }
        for session in candidates {
            let working = session.sets.filter { !$0.skipped && normalised($0.exerciseName) == key }
            if !working.isEmpty {
                return ExercisePerformance(date: session.date, sets: working)
            }
        }
        return nil
    }

    // MARK: Suggestion

    /// What to aim for on `exercise` this session, given how it went `last` time.
    static func suggestion(
        for exercise: StrengthExercise,
        last: ExercisePerformance?,
        unit: UnitPreference,
        now: Date = Date()
    ) -> LoadSuggestion {
        let targetReps = exercise.reps
        let equipment = equipment(for: exercise)

        guard exercise.durationSeconds == nil, takesLoad(equipment) else {
            return LoadSuggestion(weightKilograms: nil, reps: targetReps, reason: .unloaded)
        }
        guard let last, let top = last.topWeightKilograms else {
            return LoadSuggestion(weightKilograms: nil, reps: targetReps, reason: .firstTime)
        }

        let step = stepKilograms(for: equipment, unit: unit)
        let daysSince = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: last.date, to: now).day ?? 0

        if daysSince > returningAfterDays {
            return LoadSuggestion(
                weightKilograms: lighter(top, by: step, equipment: equipment, unit: unit),
                reps: targetReps,
                reason: .returning
            )
        }

        // An as-many-as-possible set has no target to reach: hold the load.
        guard targetReps > 0 else {
            return LoadSuggestion(
                weightKilograms: rounded(top, equipment: equipment, unit: unit),
                reps: targetReps,
                reason: .repeatLoad
            )
        }

        let topSets = last.topSets
        let reachedAll = topSets.count >= exercise.sets && topSets.allSatisfy { $0.reps >= targetReps }
        if reachedAll {
            return LoadSuggestion(
                weightKilograms: rounded(top + step, equipment: equipment, unit: unit),
                reps: targetReps,
                reason: .increase
            )
        }

        let wellShort = topSets.filter { $0.reps <= targetReps - wellShortReps }.count
        if wellShort * 2 > topSets.count {
            return LoadSuggestion(
                weightKilograms: lighter(top, by: step, equipment: equipment, unit: unit),
                reps: targetReps,
                reason: .decrease
            )
        }

        return LoadSuggestion(
            weightKilograms: rounded(top, equipment: equipment, unit: unit),
            reps: targetReps,
            reason: .repeatLoad
        )
    }

    // MARK: Equipment

    /// The exercise's equipment: stamped on newer plans, looked up by name on older ones.
    static func equipment(for exercise: StrengthExercise) -> StrengthEquipment? {
        exercise.equipment ?? StrengthLibrary.equipment(forExerciseNamed: exercise.name)
    }

    /// Whether a set of this equipment is logged with a load. Bodyweight, bands and the
    /// pull-up bar progress by reps and harder variations, not by a number.
    static func takesLoad(_ equipment: StrengthEquipment?) -> Bool {
        switch equipment {
        case .dumbbells, .kettlebell, .barbell: return true
        case .bodyweight, .resistanceBands, .pullUpBar, nil: return false
        }
    }

    /// The smallest sensible jump, in kilograms: a pair of 1.25 kg plates on a bar, the
    /// next dumbbell up, the next kettlebell (they come in 4 kg steps). In pounds, 5 lb for
    /// a bar or a dumbbell and 5 lb for a kettlebell too, since US bells step by 5.
    static func stepKilograms(for equipment: StrengthEquipment?, unit: UnitPreference) -> Double {
        switch unit {
        case .metric:
            switch equipment {
            case .barbell: return 2.5
            case .kettlebell: return 4
            default: return 2
            }
        case .imperial:
            return 5 * kilogramsPerPound
        }
    }

    // MARK: Rounding and units

    static let kilogramsPerPound = 0.45359237

    /// `weightKilograms` rounded to the nearest step in the runner's unit, as kilograms.
    static func rounded(_ weightKilograms: Double, equipment: StrengthEquipment?, unit: UnitPreference) -> Double {
        let step = displayValue(stepKilograms(for: equipment, unit: unit), unit: unit)
        let shown = displayValue(weightKilograms, unit: unit)
        let snapped = max(step, (shown / step).rounded() * step)
        return kilograms(fromDisplay: snapped, unit: unit)
    }

    /// One step lighter, never below one step.
    private static func lighter(_ weightKilograms: Double, by step: Double, equipment: StrengthEquipment?, unit: UnitPreference) -> Double {
        rounded(max(step, weightKilograms - step), equipment: equipment, unit: unit)
    }

    /// Kilograms as the runner reads them: kilograms, or pounds.
    static func displayValue(_ kilograms: Double, unit: UnitPreference) -> Double {
        unit == .metric ? kilograms : kilograms / kilogramsPerPound
    }

    /// A number the runner entered in their unit, as kilograms.
    static func kilograms(fromDisplay value: Double, unit: UnitPreference) -> Double {
        unit == .metric ? value : value * kilogramsPerPound
    }

    /// "42.5 kg" or "95 lb", with no trailing ".0".
    static func weightText(_ kilograms: Double, unit: UnitPreference) -> String {
        let value = displayValue(kilograms, unit: unit)
        let rounded = (value * 10).rounded() / 10
        let number = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
        return "\(number) \(unit == .metric ? "kg" : "lb")"
    }

    // MARK: Rest

    /// Rest between sets: two minutes after a heavy set (a load for eight reps or fewer),
    /// ninety seconds after a loaded set, a minute after bodyweight, band or timed work.
    /// The runner can still add or take off time on the rest card.
    static func restSeconds(for exercise: StrengthExercise) -> Int {
        guard exercise.durationSeconds == nil, takesLoad(equipment(for: exercise)) else { return 60 }
        return (1...8).contains(exercise.reps) ? 120 : 90
    }

    /// How far one tap on the rest card moves the timer, and its bounds.
    static let restAdjustSeconds = 15
    static let restRange: ClosedRange<Int> = 15...300

    // MARK: Words

    /// Last time's working sets in a line: "3 × 10 at 20 kg", "10, 10, 8 at 20 kg",
    /// "3 × 12" with no load. Sets at a lighter warm-up load are left out when a heavier
    /// load was used, because the top sets are what the suggestion is about.
    static func summary(of performance: ExercisePerformance, unit: UnitPreference) -> String {
        let sets = performance.topSets
        let reps = sets.map(\.reps)
        let repsText: String
        if let first = reps.first, reps.allSatisfy({ $0 == first }) {
            repsText = "\(reps.count) × \(first)"
        } else {
            repsText = reps.map(String.init).joined(separator: ", ")
        }
        guard let top = performance.topWeightKilograms else { return repsText }
        return String(
            localized: "\(repsText) at \(weightText(top, unit: unit))",
            comment: "Strength session: last time's sets, e.g. '3 × 10 at 20 kg'"
        )
    }

    /// Why the suggested load is what it is, in a short line under it. Nil when there is
    /// nothing to explain (first time, unloaded work).
    static func explanation(of suggestion: LoadSuggestion, unit: UnitPreference) -> String? {
        guard let weight = suggestion.weightKilograms else { return nil }
        let text = weightText(weight, unit: unit)
        switch suggestion.reason {
        case .increase:
            return String(localized: "Every set reached the target last time, so try \(text).", comment: "Strength session: suggestion to add weight")
        case .repeatLoad:
            return String(localized: "Stay at \(text) until every set reaches the target.", comment: "Strength session: suggestion to keep the weight")
        case .decrease:
            return String(localized: "Last time was a grind. Drop to \(text) and get the reps back.", comment: "Strength session: suggestion to reduce the weight")
        case .returning:
            return String(localized: "It's been a while. Ease back in at \(text).", comment: "Strength session: suggestion after a long break")
        case .firstTime, .unloaded:
            return nil
        }
    }

    // MARK: Strength estimate

    /// Epley's one-rep-max estimate, `w × (1 + r/30)`, or nil past ``oneRepMaxRepLimit``
    /// reps or for an empty set.
    static func estimatedOneRepMax(weightKilograms: Double, reps: Int) -> Double? {
        guard weightKilograms > 0, (1...oneRepMaxRepLimit).contains(reps) else { return nil }
        if reps == 1 { return weightKilograms }
        return weightKilograms * (1 + Double(reps) / 30)
    }

    // MARK: Legacy text weights

    /// A number read out of a weight typed as text before weights were numbers: "40 kg",
    /// "90lb", "12.5", "20 kgs". A bare number is taken in `unit`. Words ("Light",
    /// "Bodyweight", "red band") give nil.
    static func legacyWeightKilograms(from text: String?, unit: UnitPreference) -> Double? {
        guard let text else { return nil }
        let lowered = text.lowercased().replacingOccurrences(of: ",", with: ".")
        let scanner = Scanner(string: lowered)
        scanner.charactersToBeSkipped = .whitespaces
        guard let value = scanner.scanDouble(), value > 0, value < 1_000 else { return nil }
        let rest = lowered[scanner.currentIndex...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("lb") || rest.hasPrefix("pound") {
            return value * kilogramsPerPound
        }
        if rest.hasPrefix("kg") || rest.hasPrefix("kilo") {
            return value
        }
        guard rest.isEmpty else { return nil }
        return kilograms(fromDisplay: value, unit: unit)
    }

    private static func normalised(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
