import Foundation

// MARK: - CustomWorkoutDraft

/// The builder screen's working copy of a custom workout (Custom workouts, PR 2).
///
/// ``WorkoutStructure`` says how a session runs; this says how a runner edits one. A
/// warm-up is "none, a distance or a time" rather than a segment whose fields happen to be
/// empty, and a step's length remembers which of the two it is even while its value is
/// being typed. ``structure()`` turns it into the stored form and ``init(name:structure:notes:)``
/// reads one back, so an edit round-trips through a ``SavedWorkout``.
///
/// Pure and `Sendable`, with no SwiftUI, so the conversion is tested without a view.
public struct CustomWorkoutDraft: Equatable, Sendable {

    public var name: String
    public var notes: String
    public var warmup: StepLength?
    public var sets: [SetDraft]
    public var cooldown: StepLength?

    /// How long a step lasts.
    public enum StepLength: Equatable, Hashable, Sendable {
        case distance(meters: Double)
        case time(seconds: Double)

        public var isDistance: Bool {
            if case .distance = self { return true }
            return false
        }
    }

    /// What the runner does between reps.
    public enum RecoveryKind: String, CaseIterable, Equatable, Sendable {
        case jog, walk, rest

        /// The recovery segment's label, which the guided run and its cues show.
        public var label: String {
            switch self {
            case .jog: String(localized: "Jog", comment: "Custom workout recovery: jog between reps")
            case .walk: String(localized: "Walk", comment: "Custom workout recovery: walk between reps")
            case .rest: String(localized: "Rest", comment: "Custom workout recovery: stand still between reps")
            }
        }

        public init(label: String) {
            let lowered = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self = Self.allCases.first { $0.label.lowercased() == lowered || $0.rawValue == lowered } ?? .jog
        }
    }

    /// One block of reps.
    public struct SetDraft: Equatable, Identifiable, Sendable {
        public var id = UUID()
        /// Optional name, for example "Tempo". Empty falls back to the guided run's "Work".
        public var label: String = ""
        public var repetitions: Int = 1
        public var work: StepLength = .distance(meters: 400)
        /// Seconds per kilometre, or `nil` for "no pace, just run it".
        public var workPaceSecondsPerKm: Double?
        /// `nil` is no recovery: the reps run back to back.
        public var recovery: StepLength?
        public var recoveryKind: RecoveryKind = .jog

        public init(
            id: UUID = UUID(),
            label: String = "",
            repetitions: Int = 1,
            work: StepLength = .distance(meters: 400),
            workPaceSecondsPerKm: Double? = nil,
            recovery: StepLength? = nil,
            recoveryKind: RecoveryKind = .jog
        ) {
            self.id = id
            self.label = label
            self.repetitions = repetitions
            self.work = work
            self.workPaceSecondsPerKm = workPaceSecondsPerKm
            self.recovery = recovery
            self.recoveryKind = recoveryKind
        }
    }

    public init(
        name: String = "",
        notes: String = "",
        warmup: StepLength? = nil,
        sets: [SetDraft] = [SetDraft()],
        cooldown: StepLength? = nil
    ) {
        self.name = name
        self.notes = notes
        self.warmup = warmup
        self.sets = sets
        self.cooldown = cooldown
    }

    // MARK: To and from the stored form

    /// The structure to save, without its totals (``CustomWorkoutRules/finalized(_:fallback:)``
    /// adds those). The warm-up, cool-down and recoveries are run easy, so they carry no
    /// pace: a pace there would have the Workout app alerting a runner for jogging slowly.
    public func structure() -> WorkoutStructure {
        WorkoutStructure(
            warmup: Self.segment(warmup, label: String(localized: "Warm-up")),
            mainSets: sets.map { set in
                WorkoutSet(
                    repetitions: set.repetitions,
                    workSegment: Self.segment(set.work, label: "", pace: set.workPaceSecondsPerKm),
                    recoverySegment: Self.segment(set.recovery, label: set.recovery == nil ? "" : set.recoveryKind.label),
                    label: set.label.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            },
            cooldown: Self.segment(cooldown, label: String(localized: "Cool-down")),
            totalEstimatedDistanceMeters: 0,
            totalEstimatedDurationSeconds: 0
        )
    }

    /// Reads a stored workout back for editing. A segment with neither a distance nor a time
    /// reads as left out.
    public init(name: String, structure: WorkoutStructure, notes: String?) {
        self.init(
            name: name,
            notes: notes ?? "",
            warmup: Self.length(of: structure.warmup),
            sets: structure.mainSets.map { set in
                SetDraft(
                    label: set.label,
                    repetitions: set.repetitions,
                    work: Self.length(of: set.workSegment) ?? .distance(meters: 400),
                    workPaceSecondsPerKm: set.workSegment.targetPaceSecondsPerKm,
                    recovery: Self.length(of: set.recoverySegment),
                    recoveryKind: RecoveryKind(label: set.recoverySegment.label)
                )
            },
            cooldown: Self.length(of: structure.cooldown)
        )
    }

    private static func segment(_ length: StepLength?, label: String, pace: Double? = nil) -> WorkoutSegment {
        switch length {
        case .distance(let meters):
            WorkoutSegment(distanceMeters: meters, targetPaceSecondsPerKm: pace, label: label)
        case .time(let seconds):
            WorkoutSegment(durationSeconds: seconds, targetPaceSecondsPerKm: pace, label: label)
        case nil:
            // Left out: no length and no name, so it is skipped when run (`isEmpty`).
            WorkoutSegment(label: "")
        }
    }

    private static func length(of segment: WorkoutSegment) -> StepLength? {
        if let meters = segment.distanceMeters, meters > 0 { return .distance(meters: meters) }
        if let seconds = segment.durationSeconds, seconds > 0 { return .time(seconds: seconds) }
        return nil
    }

    // MARK: Editing

    /// Adds a set copied from the last one, which is what a runner building "3 × 1 mile,
    /// then 4 × 400 m" usually wants to start the next set from.
    public mutating func addSet() {
        var next = sets.last ?? SetDraft()
        next.id = UUID()
        sets.append(next)
    }
}

// MARK: - Typed values

/// Parsing and formatting of the "m:ss" fields the builder uses for times and paces.
public enum MinutesSecondsText {

    /// "1:30" is 90 s, "12" is 12 minutes, "1:02:00" is 62 minutes. `nil` for anything else,
    /// including seconds of 60 or more ("1:75").
    public static func seconds(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count, values.allSatisfy({ $0 >= 0 }) else { return nil }
        switch values.count {
        case 1:
            return values[0] > 0 ? Double(values[0] * 60) : nil
        case 2:
            guard values[1] < 60 else { return nil }
            let total = values[0] * 60 + values[1]
            return total > 0 ? Double(total) : nil
        default:
            guard values[1] < 60, values[2] < 60 else { return nil }
            let total = values[0] * 3_600 + values[1] * 60 + values[2]
            return total > 0 ? Double(total) : nil
        }
    }

    /// "1:30", or "1:02:00" past an hour.
    public static func text(seconds: Double) -> String {
        seconds.durationString
    }

    /// A pace typed per the runner's unit, as seconds per kilometre.
    public static func paceSecondsPerKm(from text: String, unit: UnitPreference) -> Double? {
        guard let perUnit = seconds(from: text) else { return nil }
        return unit == .metric ? perUnit : perUnit / 1.60934
    }

    /// Seconds per kilometre shown per the runner's unit, "4:05". Rounded rather than
    /// truncated, so a pace typed per mile and stored per kilometre reads back as typed
    /// ("8:00", not "7:59").
    public static func paceText(secondsPerKm: Double, unit: UnitPreference) -> String {
        let perUnit = Int((unit == .metric ? secondsPerKm : secondsPerKm * 1.60934).rounded())
        return String(format: "%d:%02d", perUnit / 60, perUnit % 60)
    }
}

// MARK: - Distance units

/// The units a step's distance can be typed in. Track reps read in metres for everyone.
public enum CustomWorkoutDistanceUnit: String, CaseIterable, Sendable {
    case meters, kilometers, miles

    public var metersPerUnit: Double {
        switch self {
        case .meters: 1
        case .kilometers: 1_000
        case .miles: 1_609.344
        }
    }

    public var symbol: String {
        switch self {
        case .meters: "m"
        case .kilometers: "km"
        case .miles: "mi"
        }
    }

    /// The unit a stored distance reads best in: metres under a kilometre, else a whole
    /// number of miles or kilometres if it is one, else the runner's unit.
    public static func display(for meters: Double, unit: UnitPreference) -> CustomWorkoutDistanceUnit {
        if meters < 1_000 { return .meters }
        let miles = meters / CustomWorkoutDistanceUnit.miles.metersPerUnit
        if abs(miles - miles.rounded()) < 0.001 { return .miles }
        if abs(meters / 1_000 - (meters / 1_000).rounded()) < 0.001 { return .kilometers }
        return unit == .metric ? .kilometers : .miles
    }
}
