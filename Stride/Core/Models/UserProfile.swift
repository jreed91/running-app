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
    /// User-defined goal distance in meters when `goalRace == .custom`; nil otherwise.
    var customDistanceMeters: Double?
    var raceName: String?
    var raceDate: Date?
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
    /// Optional age, used only to suggest a max HR (Tanaka). Nil when the user hasn't entered it.
    var age: Int?
    /// User's max heart rate in bpm, driving the HR-zone breakdowns (A6). Nil until set; a value
    /// entered by the user overrides the age-based estimate.
    var maxHeartRateBPM: Int?
    /// JSON-encoded `[Int]` backing store for preferred run weekdays.
    /// Access via the `preferredRunDayIndices` extension property — never persist `[Int]` directly.
    var preferredRunDayIndicesData: Data?
    /// Estimated due date, set when the runner is building a pregnancy plan. Nil otherwise —
    /// it is what makes `PregnancyPlanService` able to run at all.
    var dueDate: Date?
    /// When the runner confirmed the contraindication screen and that they have discussed
    /// running with their maternity provider. `PregnancyPlanService.generatePlan` refuses to
    /// build a plan while this is nil; it is the app's record that the gate was passed, not
    /// a clinical clearance, and it is re-confirmed every time a plan is built.
    var pregnancyClearedAt: Date?
    /// Weekly running minutes before pregnancy. A pregnancy plan tapers from *this*, not from
    /// a VDOT-derived volume, because what a runner was actually doing is the only defensible
    /// starting point for a percentage taper.
    var prePregnancyWeeklyRunMinutes: Int?
    /// Whether the runner habitually did vigorous-intensity running before pregnancy. ACOG
    /// Committee Opinion 804 keys its "may continue" allowance on exactly this, so it is
    /// stored as its own answer rather than inferred from `fitnessLevel`.
    var pregnancyHabituallyVigorous: Bool?
    /// JSON-encoded `[String]` of `StrengthEquipment` rawValues the user owns.
    var selectedEquipmentData: Data?
    /// Raw-backed storage for `strengthFocus` to keep CloudKit fields primitive.
    var strengthFocusRaw: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        name: String,
        goalRace: RaceType,
        goalFinishTime: TimeInterval,
        raceName: String? = nil,
        raceDate: Date? = nil,
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
        self.raceName = raceName
        self.raceDate = raceDate
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

    /// The age assumed for HR estimates before the runner tells us theirs.
    ///
    /// Onboarding and Settings both display an age-derived max HR before `age` is set, and
    /// they have to assume the same number or they show the runner two different values for
    /// the same field (S7).
    static let assumedAge = 30

    /// Tanaka (2001) age-predicted maximum heart rate: 208 − 0.7·age.
    static func estimatedMaxHeartRate(forAge age: Int) -> Int {
        Int((208.0 - 0.7 * Double(age)).rounded())
    }

    /// Effective max HR for zone math: an explicit user value wins, else the age-based
    /// estimate, else nil (no zones can be computed until one is available).
    var effectiveMaxHeartRate: Int? {
        if let maxHeartRateBPM, maxHeartRateBPM > 0 { return maxHeartRateBPM }
        if let age, age > 0 { return Self.estimatedMaxHeartRate(forAge: age) }
        return nil
    }

    /// VDOT implied by the runner's own 5K estimate, before any run has been logged.
    ///
    /// Onboarding computes and *shows* this number ("VDOT 36 · base fitness") and builds the
    /// plan's pace zones from it, so a screen that reports `--` until the first logged run
    /// reads as data loss rather than as "not measured yet" (S8).
    var baselineVDOT: Double? {
        guard let time = currentEstimated5KTimeSeconds, time > 0 else { return nil }
        let value = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: time)
        return value.isFinite && value > 20 ? value : nil
    }

    /// The goal race distance in meters, honoring a user-defined custom distance.
    var effectiveRaceDistanceMeters: Double {
        if goalRace.usesCustomDistance, let custom = customDistanceMeters, custom > 0 {
            return custom
        }
        return goalRace.distanceMeters
    }

    /// Weekday indices (0 = Monday … 6 = Sunday) the user prefers to run.
    /// Empty means "spread evenly based on weeklyRunDays".
    var preferredRunDayIndices: [Int] {
        get { preferredRunDayIndicesData?.decode([Int].self) ?? [] }
        set { preferredRunDayIndicesData = newValue.isEmpty ? nil : .encoded(newValue, keeping: preferredRunDayIndicesData) }
    }

    var selectedEquipment: [StrengthEquipment] {
        get {
            guard let data = selectedEquipmentData,
                  let rawValues = data.decode([String].self) else { return [] }
            return rawValues.compactMap { StrengthEquipment(rawValue: $0) }
        }
        set {
            selectedEquipmentData = newValue.isEmpty ? nil : .encoded(newValue.map(\.rawValue), keeping: selectedEquipmentData)
        }
    }

    var strengthFocus: StrengthFocus {
        get { strengthFocusRaw.flatMap { StrengthFocus(rawValue: $0) } ?? .runningSpecific }
        set { strengthFocusRaw = newValue.rawValue }
    }
}
