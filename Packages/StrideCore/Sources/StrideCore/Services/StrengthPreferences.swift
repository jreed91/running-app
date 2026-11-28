import Foundation

// MARK: - StrengthPreferences

/// How much strength the runner wants: sessions a week and minutes a session. Nil means
/// "let the plan decide", which is what every runner had before these existed.
///
/// Kept in `UserDefaults`, like ``StrengthSessionCheckpoint``, rather than on
/// `UserProfile`: a new stored property there is a CloudKit schema deployment (AGENTS.md,
/// "Changing the schema means redeploying it"). The cost is that the choice is per device;
/// the plan it shaped still syncs, so a second device shows the same sessions.
struct StrengthPreferences: Codable, Equatable, Sendable {
    /// Strength sessions a week, 0 to 3. Nil: the plan's own rule (two in base and build
    /// for running-specific focus, one otherwise).
    var daysPerWeek: Int?
    /// Target minutes per session, one of ``sessionLengthOptions``. Nil: the phase's full
    /// session.
    var sessionMinutes: Int?
    /// Library exercises the runner never wants suggested, by name. New sessions leave
    /// them out (the next exercise in line takes the place), and Swap doesn't offer them.
    var excludedExercises: [String] = []
    /// Standing swaps, original name → stand-in name: "Swap in every session" on the
    /// session screen. New sessions use the stand-in wherever the original would go.
    var replacements: [String: String] = [:]

    init(
        daysPerWeek: Int? = nil,
        sessionMinutes: Int? = nil,
        excludedExercises: [String] = [],
        replacements: [String: String] = [:]
    ) {
        self.daysPerWeek = daysPerWeek
        self.sessionMinutes = sessionMinutes
        self.excludedExercises = excludedExercises
        self.replacements = replacements
    }

    // Written out so preferences saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        daysPerWeek = try container.decodeIfPresent(Int.self, forKey: .daysPerWeek)
        sessionMinutes = try container.decodeIfPresent(Int.self, forKey: .sessionMinutes)
        excludedExercises = try container.decodeIfPresent([String].self, forKey: .excludedExercises) ?? []
        replacements = try container.decodeIfPresent([String: String].self, forKey: .replacements) ?? [:]
    }

    /// Always use `standIn` where `original` would go. A swap back to the original drops
    /// the rule; a stand-in that was itself swapped follows to the newest choice.
    mutating func replace(_ original: String, with standIn: String) {
        let root = replacements.first { $0.value == original }?.key ?? original
        if standIn == root {
            replacements[root] = nil
        } else {
            replacements[root] = standIn
        }
    }

    /// ``excludedExercises`` as a set, for the library.
    var excluded: Set<String> { Set(excludedExercises) }

    /// Adds `name` to the exclusions, once, keeping them in the order chosen.
    mutating func exclude(_ name: String) {
        guard !excludedExercises.contains(name) else { return }
        excludedExercises.append(name)
    }

    mutating func include(_ name: String) {
        excludedExercises.removeAll { $0 == name }
    }

    static let daysPerWeekRange = 0...3
    static let sessionLengthOptions = [25, 35, 45]
    static let defaultsKey = "strength.preferences"

    // MARK: Plan rules

    /// Strength sessions in a week of a standard plan.
    ///
    /// Without a choice it is the generator's long-standing rule. With one, the runner's
    /// number wins, except in a taper, which never gets more than one: race week is not
    /// the week to build strength, whatever was asked for in March.
    func strengthDays(phase: TrainingPhase, focus: StrengthFocus, isBeginner: Bool) -> Int {
        guard let daysPerWeek else {
            switch (phase, focus) {
            case (.taper, _):           return isBeginner ? 0 : 1
            case (.peak, _):            return 1
            case (_, .generalStrength): return 1
            default:                    return 2
            }
        }
        let chosen = min(Self.daysPerWeekRange.upperBound, max(Self.daysPerWeekRange.lowerBound, daysPerWeek))
        return phase == .taper ? min(chosen, 1) : chosen
    }

    /// The days of a week (0 = Monday) that strength goes on, earliest first: free, not
    /// the day before or after a quality session or long run, and never from the day
    /// before the race on. At most `count`; a week without enough such days gets fewer,
    /// as it always has, rather than strength the day before a long run.
    static func strengthDayOffsets(
        count: Int,
        occupied: Set<Int>,
        hardDays: Set<Int>,
        raceDay: Int?
    ) -> [Int] {
        guard count > 0 else { return [] }
        let candidates = (0...6).filter { offset in
            !occupied.contains(offset)
                && !(raceDay.map { offset >= $0 - 1 } ?? false)
                && !hardDays.contains(offset - 1)
                && !hardDays.contains(offset + 1)
        }
        return Array(candidates.prefix(count))
    }

    // MARK: Storage

    static func load(from defaults: UserDefaults = .standard) -> StrengthPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(StrengthPreferences.self, from: data)
        else { return StrengthPreferences() }
        return stored
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
