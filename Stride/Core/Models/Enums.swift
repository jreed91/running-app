import Foundation

// MARK: - RaceType

enum RaceType: String, Codable, CaseIterable, Sendable {
    case maintainFitness = "Maintain Fitness"
    case fiveK = "5K"
    case halfMarathon = "Half Marathon"
    case marathon = "Marathon"
    /// A user-defined goal distance. The actual distance is stored alongside the
    /// race type on `UserProfile`/`TrainingPlan` as `customDistanceMeters`; the
    /// value here is only a fallback used when no distance has been supplied.
    case custom = "Custom"

    var displayName: String {
        self == .custom ? "Custom Distance" : rawValue
    }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    var localizedName: String {
        switch self {
        case .maintainFitness: return String(localized: "Maintain Fitness", comment: "Goal race type")
        case .fiveK:           return String(localized: "5K", comment: "Goal race type")
        case .halfMarathon:    return String(localized: "Half Marathon", comment: "Goal race type")
        case .marathon:        return String(localized: "Marathon", comment: "Goal race type")
        case .custom:          return String(localized: "Custom Distance", comment: "Goal race type")
        }
    }

    var isGoalRace: Bool {
        self != .maintainFitness
    }

    /// Whether this race type carries a user-defined distance. When `true`, callers
    /// should prefer the stored `customDistanceMeters` over `distanceMeters`.
    var usesCustomDistance: Bool { self == .custom }

    var distanceMeters: Double {
        switch self {
        case .maintainFitness: return 10_000
        case .fiveK:        return 5_000
        case .halfMarathon: return 21_097.5
        case .marathon:     return 42_195
        case .custom:       return 10_000   // fallback only — see `customDistanceMeters`
        }
    }

    var typicalWeeks: ClosedRange<Int> {
        switch self {
        case .maintainFitness: return 6...16
        case .fiveK:        return 8...12
        case .halfMarathon: return 12...20
        case .marathon:     return 16...24
        case .custom:       return 6...24
        }
    }

    /// The closest standard race used to derive training characteristics
    /// (phasing, quality sessions, intervals, and pace targets) for a given
    /// distance. Returns `self` for the standard race types; for `.custom` it
    /// maps the supplied distance onto the nearest training archetype.
    func trainingStyle(forDistanceMeters meters: Double) -> RaceType {
        guard self == .custom else { return self }
        switch meters {
        case ..<8_000:   return .fiveK          // 5K-and-under: speed focused
        case ..<32_000:  return .halfMarathon   // 10K–30K: threshold/tempo focused
        default:         return .marathon       // 30K+: long-run focused
        }
    }
}

// MARK: - PlanKind

/// What kind of plan a `TrainingPlan` is.
///
/// A separate axis from `RaceType` rather than another case on it, because the two answer
/// different questions: `RaceType` is *what the runner is training for*, `PlanKind` is *which
/// generator built the plan and which rules govern it*. A pregnancy plan has no goal race —
/// it carries `.maintainFitness` — but it must never be re-paced from VDOT, adapted by the
/// AI coach, or handed intervals, and that is what this discriminates on.
///
/// Decoding an unknown raw value falls back to `.standard` so an older client reading a
/// synced plan degrades rather than fails, the way `FitnessLevel` does.
enum PlanKind: String, Codable, CaseIterable, Sendable {
    case standard
    case pregnancy

    var displayName: String {
        switch self {
        case .standard:  return "Training Plan"
        case .pregnancy: return "Pregnancy Plan"
        }
    }

    var localizedName: String {
        switch self {
        case .standard:  return String(localized: "Training Plan", comment: "Kind of training plan")
        case .pregnancy: return String(localized: "Pregnancy Plan", comment: "Kind of training plan")
        }
    }
}

// MARK: - FitnessLevel

enum FitnessLevel: String, Codable, CaseIterable, Sendable {
    case beginner
    case intermediate
    case advanced
    /// Added so onboarding's four-way choice has four outcomes. It used to fold into
    /// `.advanced`, which the screen itself gave away: "Experienced" and "Competitive" both
    /// read "Plan starts ~25 mi/week" (S10). Decoding an unknown raw value falls back to
    /// `.beginner` at every call site, so an older client reading a synced profile degrades
    /// rather than fails.
    case competitive

    var displayName: String { rawValue.capitalized }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    ///
    /// These are the words onboarding asks the question in. They used to be a second
    /// vocabulary — pick "Recreational" in onboarding and Settings reported "Intermediate",
    /// a word the runner was never shown (S9).
    var localizedName: String {
        switch self {
        case .beginner:     return String(localized: "New to running", comment: "Fitness level")
        case .intermediate: return String(localized: "Recreational", comment: "Fitness level")
        case .advanced:     return String(localized: "Experienced", comment: "Fitness level")
        case .competitive:  return String(localized: "Competitive", comment: "Fitness level")
        }
    }

    /// Starting weekly volume in km, scaled to the target race distance.
    ///
    /// 5K plans use lower base volumes than half marathon plans because the
    /// race-specific adaptations require less overall mileage and more speed work.
    func startingWeeklyKm(for raceType: RaceType) -> Double {
        switch raceType {
        case .maintainFitness:
            switch self {
            case .beginner:     return 12
            case .intermediate: return 20
            case .advanced:     return 30
            case .competitive:  return 38
            }
        case .fiveK:
            switch self {
            case .beginner:     return 15   // ~9 mi/wk start, ~14 mi/wk peak
            case .intermediate: return 20   // ~12 mi/wk start, ~19 mi/wk peak
            case .advanced:     return 40   // ~25 mi/wk start, ~37 mi/wk peak
            case .competitive:  return 52   // ~32 mi/wk start, ~48 mi/wk peak
            }
        case .halfMarathon:
            switch self {
            case .beginner:     return 25   // ~15 mi/wk
            case .intermediate: return 40   // ~25 mi/wk
            case .advanced:     return 60   // ~37 mi/wk
            case .competitive:  return 75   // ~47 mi/wk
            }
        case .marathon:
            switch self {
            case .beginner:     return 40   // ~25 mi/wk
            case .intermediate: return 55   // ~34 mi/wk
            case .advanced:     return 80   // ~50 mi/wk
            case .competitive:  return 100  // ~62 mi/wk
            }
        case .custom:
            // Custom distances route through `trainingStyle(forDistanceMeters:)`
            // during generation, so this is only a neutral mid-range fallback.
            switch self {
            case .beginner:     return 25
            case .intermediate: return 40
            case .advanced:     return 60
            case .competitive:  return 75
            }
        }
    }
}

// MARK: - Gender

enum Gender: String, Codable, CaseIterable, Sendable {
    case male               = "male"
    case female             = "female"
    case preferNotToShare   = "prefer_not_to_share"

    var displayName: String {
        switch self {
        case .male:             return "Male"
        case .female:           return "Female"
        case .preferNotToShare: return "Prefer not to share"
        }
    }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    var localizedName: String {
        switch self {
        case .male:             return String(localized: "Male", comment: "Gender")
        case .female:           return String(localized: "Female", comment: "Gender")
        case .preferNotToShare: return String(localized: "Prefer not to share", comment: "Gender")
        }
    }
}

// MARK: - WorkoutType

enum WorkoutType: String, Codable, CaseIterable, Sendable {
    case easy = "Easy"
    case tempo = "Tempo"
    case interval = "Interval"
    case longRun = "Long Run"
    case race = "Race"
    case rest = "Rest"
    case crossTraining = "Cross Training"
    case strength = "Strength"
    /// A walk imported from Apple Health.
    ///
    /// The only type here that no generator ever prescribes: it exists so a walking
    /// workout can be *recorded* without being mistaken for a run. Everything that
    /// reasons about training load asks `countsAsRunning` (or `Sequence.runsOnly`)
    /// rather than listing types, because a walk in the weekly mileage, the VDOT
    /// trend, or the streak is a wrong number rather than a missing one.
    case walk = "Walk"

    var displayName: String { rawValue }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    var localizedName: String {
        switch self {
        case .easy:          return String(localized: "Easy", comment: "Workout type")
        case .tempo:         return String(localized: "Tempo", comment: "Workout type")
        case .interval:      return String(localized: "Interval", comment: "Workout type")
        case .longRun:       return String(localized: "Long Run", comment: "Workout type")
        case .race:          return String(localized: "Race", comment: "Workout type")
        case .rest:          return String(localized: "Rest", comment: "Workout type")
        case .crossTraining: return String(localized: "Cross Training", comment: "Workout type")
        case .strength:      return String(localized: "Strength", comment: "Workout type")
        case .walk:          return String(localized: "Walk", comment: "Workout type")
        }
    }

    var isQualitySession: Bool {
        switch self {
        case .tempo, .interval, .race: return true
        default: return false
        }
    }

    /// True for workout types that are fulfilled by a run and can therefore be
    /// linked to an imported `RunWorkout`. Strength, cross-training, rest days, and
    /// walks must never be matched to (or completed by) an imported run.
    var isRunType: Bool {
        switch self {
        case .easy, .tempo, .interval, .longRun, .race: return true
        case .rest, .crossTraining, .strength, .walk: return false
        }
    }

    /// Whether a *completed* workout of this type is running that counts as training.
    ///
    /// `isRunType` answers a question about the plan — "can an imported run complete a
    /// day scheduled as this?" — and every non-run type answers it the same way, which
    /// is why the two are separate. This one is asked of recorded history: weekly volume,
    /// VDOT, pace trends, personal records, the streak, and everything the coach reads.
    /// `.walk` is the case that makes the distinction earn its keep — a walk is real
    /// history and belongs in the log, but it is not a run and must never be averaged,
    /// totalled, or extrapolated with them.
    var countsAsRunning: Bool { self != .walk }

    /// The kind of session a workout type represents.
    ///
    /// A training day can legitimately hold one session of each kind — a plan pairs
    /// an easy run with a gym session, and a missed-workout shift can move a run onto
    /// a strength day. Everything that reasons about a day therefore has to treat the
    /// kinds separately: collapsing "every workout on this date" into one is what
    /// silently deleted the runner's strength session (N6), and the dashboard's day
    /// resolution orders and renders a day's sessions by kind (N12).
    enum SessionKind: String, Sendable {
        case run, walk, strength, crossTraining, rest
    }

    var sessionKind: SessionKind {
        switch self {
        case .easy, .tempo, .interval, .longRun, .race: return .run
        case .walk:          return .walk
        case .strength:      return .strength
        case .crossTraining: return .crossTraining
        case .rest:          return .rest
        }
    }
}

// MARK: - TrainingPhase

enum TrainingPhase: String, Codable, Sendable {
    case base = "Base"
    case build = "Build"
    case peak = "Peak"
    case taper = "Taper"

    var displayName: String { rawValue }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    var localizedName: String {
        switch self {
        case .base:  return String(localized: "Base", comment: "Training phase")
        case .build: return String(localized: "Build", comment: "Training phase")
        case .peak:  return String(localized: "Peak", comment: "Training phase")
        case .taper: return String(localized: "Taper", comment: "Training phase")
        }
    }
}

// MARK: - RecoveryType

enum RecoveryType: String, Codable, Sendable {
    case walk
    case jog
    case standing
}

// MARK: - RouteType

enum RouteType: String, Codable, CaseIterable, Sendable {
    case loop = "Loop"
    case outAndBack = "Out & Back"

    var displayName: String { rawValue }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    var localizedName: String {
        switch self {
        case .loop:       return String(localized: "Loop", comment: "Route shape")
        case .outAndBack: return String(localized: "Out & Back", comment: "Route shape")
        }
    }

    var systemImage: String {
        switch self {
        case .loop:       return "arrow.trianglehead.2.clockwise"
        case .outAndBack: return "arrow.left.arrow.right"
        }
    }

    var strideIcon: StrideIconName {
        switch self {
        case .loop:       return .run
        case .outAndBack: return .ruler
        }
    }
}

// MARK: - WorkoutLocation

enum WorkoutLocation: String, Codable, CaseIterable, Sendable {
    case outdoor = "Outdoor"
    case indoor = "Indoor"

    var displayName: String { rawValue }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    var localizedName: String {
        switch self {
        case .outdoor: return String(localized: "Outdoor", comment: "Where a run happens")
        case .indoor:  return String(localized: "Indoor", comment: "Where a run happens")
        }
    }

    var systemImage: String {
        switch self {
        case .outdoor: return "figure.run"
        case .indoor:  return "house.fill"
        }
    }
}

// MARK: - UnitPreference

enum UnitPreference: String, CaseIterable, Sendable {
    case metric = "metric"
    case imperial = "imperial"

    /// What this device already measures in, used when the runner has never chosen.
    ///
    /// Onboarding used to spend a whole step of nine asking this (U10), with `.metric`
    /// as the answer it assumed if you skipped — wrong for every runner in the US.
    /// The system already knows, so the step became a control on the "About you" step
    /// instead of a question of its own.
    ///
    /// Anything that is not the metric system maps to miles: `.uk` measures road
    /// distance in miles, which is the only measurement this app makes.
    static var localeDefault: UnitPreference {
        Locale.current.measurementSystem == .metric ? .metric : .imperial
    }

    var displayName: String {
        switch self {
        case .metric: return "Kilometers"
        case .imperial: return "Miles"
        }
    }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    var localizedName: String {
        switch self {
        case .metric:   return String(localized: "Kilometers", comment: "Unit preference")
        case .imperial: return String(localized: "Miles", comment: "Unit preference")
        }
    }

    var distanceLabel: String {
        switch self {
        case .metric: return "km"
        case .imperial: return "mi"
        }
    }

    /// Uppercased distance label used as a split/segment header (e.g. "KM" / "MI").
    var splitLabel: String { distanceLabel.uppercased() }

    /// Length in metres of one split bucket in this unit: 1 km or 1 mile.
    var splitLengthMeters: Double {
        switch self {
        case .metric:   return 1_000
        case .imperial: return 1_609.344
        }
    }

    var paceLabel: String {
        switch self {
        case .metric: return "min/km"
        case .imperial: return "min/mi"
        }
    }

    var elevationLabel: String {
        switch self {
        case .metric:   return "m"
        case .imperial: return "ft"
        }
    }
}


// MARK: - AIProvider

/// AI coaching runs entirely on Apple's Foundation Models framework — there are no
/// third-party providers and no API keys. `appleOnDevice` uses the on-device
/// Apple Intelligence model; `applePrivateCloud` routes the heaviest requests to
/// Apple's Private Cloud Compute model (iOS 27+). Both are keyless and private.
enum AIProvider: String, CaseIterable, Sendable {
    case appleOnDevice = "apple_on_device"
    case applePrivateCloud = "apple_pcc"

    var displayName: String {
        switch self {
        case .appleOnDevice: return "On-device (Apple Intelligence)"
        case .applePrivateCloud: return "Apple Private Cloud Compute"
        }
    }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    var localizedName: String {
        switch self {
        case .appleOnDevice:
            return String(localized: "On-device (Apple Intelligence)", comment: "Where AI coaching runs")
        case .applePrivateCloud:
            return String(localized: "Apple Private Cloud Compute", comment: "Where AI coaching runs")
        }
    }

    /// Apple's server-backed model (Private Cloud Compute); only meaningful on iOS 27+.
    var usesPrivateCloudCompute: Bool { self == .applePrivateCloud }
}

// MARK: - StrengthEquipment

enum StrengthEquipment: String, Codable, CaseIterable, Sendable {
    case bodyweight      = "Bodyweight"
    case dumbbells       = "Dumbbells"
    case resistanceBands = "Resistance Bands"
    case pullUpBar       = "Pull-Up Bar"
    case kettlebell      = "Kettlebell"
    case barbell         = "Barbell"

    var displayName: String { rawValue }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    var localizedName: String {
        switch self {
        case .bodyweight:      return String(localized: "Bodyweight", comment: "Strength equipment")
        case .dumbbells:       return String(localized: "Dumbbells", comment: "Strength equipment")
        case .resistanceBands: return String(localized: "Resistance Bands", comment: "Strength equipment")
        case .pullUpBar:       return String(localized: "Pull-Up Bar", comment: "Strength equipment")
        case .kettlebell:      return String(localized: "Kettlebell", comment: "Strength equipment")
        case .barbell:         return String(localized: "Barbell", comment: "Strength equipment")
        }
    }

    var systemImage: String {
        switch self {
        case .bodyweight:      return "figure.strengthtraining.traditional"
        case .dumbbells:       return "dumbbell.fill"
        case .resistanceBands: return "circle.grid.2x2.fill"
        case .pullUpBar:       return "minus.rectangle.fill"
        case .kettlebell:      return "drop.fill"
        case .barbell:         return "line.horizontal.3"
        }
    }
}

// MARK: - StrengthFocus

enum StrengthFocus: String, Codable, CaseIterable, Sendable {
    case runningSpecific = "Running-Specific"
    case generalStrength = "General Strength"

    var displayName: String { rawValue }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    var localizedName: String {
        switch self {
        case .runningSpecific: return String(localized: "Running-Specific", comment: "Strength focus")
        case .generalStrength: return String(localized: "General Strength", comment: "Strength focus")
        }
    }

    var subtitle: String {
        switch self {
        case .runningSpecific:
            return String(localized: "Glutes, hips, core, and single-leg stability", comment: "Strength focus subtitle")
        case .generalStrength:
            return String(localized: "Full-body strength with push, pull, and hinge patterns", comment: "Strength focus subtitle")
        }
    }
}
