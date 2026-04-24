import Foundation

// MARK: - RaceType

enum RaceType: String, Codable, CaseIterable, Sendable {
    case maintainFitness = "Maintain Fitness"
    case fiveK = "5K"
    case halfMarathon = "Half Marathon"
    case marathon = "Marathon"

    var displayName: String { rawValue }

    var distanceMeters: Double {
        switch self {
        case .maintainFitness: return 10_000
        case .fiveK:        return 5_000
        case .halfMarathon: return 21_097.5
        case .marathon:     return 42_195
        }
    }

    var typicalWeeks: ClosedRange<Int> {
        switch self {
        case .maintainFitness: return 6...16
        case .fiveK:        return 8...12
        case .halfMarathon: return 12...20
        case .marathon:     return 16...24
        }
    }
}

// MARK: - FitnessLevel

enum FitnessLevel: String, Codable, CaseIterable, Sendable {
    case beginner
    case intermediate
    case advanced

    var displayName: String { rawValue.capitalized }

    /// Starting weekly volume in km, scaled to the target race distance.
    ///
    /// 5K plans use lower base volumes than half marathon plans because the
    /// race-specific adaptations require less overall mileage and more speed work.
    func startingWeeklyKm(for raceType: RaceType) -> Double {
        switch raceType {
        case .maintainFitness:
            switch self {
            case .beginner:     return 18
            case .intermediate: return 30
            case .advanced:     return 45
            }
        case .fiveK:
            switch self {
            case .beginner:     return 15   // ~9 mi/wk start, ~14 mi/wk peak
            case .intermediate: return 20   // ~12 mi/wk start, ~19 mi/wk peak
            case .advanced:     return 40   // ~25 mi/wk start, ~37 mi/wk peak
            }
        case .halfMarathon:
            switch self {
            case .beginner:     return 25   // ~15 mi/wk
            case .intermediate: return 40   // ~25 mi/wk
            case .advanced:     return 60   // ~37 mi/wk
            }
        case .marathon:
            switch self {
            case .beginner:     return 40   // ~25 mi/wk
            case .intermediate: return 55   // ~34 mi/wk
            case .advanced:     return 80   // ~50 mi/wk
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

    var displayName: String { rawValue }

    var isQualitySession: Bool {
        switch self {
        case .tempo, .interval, .race: return true
        default: return false
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

// MARK: - UnitPreference

enum UnitPreference: String, CaseIterable, Sendable {
    case metric = "metric"
    case imperial = "imperial"

    var displayName: String {
        switch self {
        case .metric: return "Kilometers"
        case .imperial: return "Miles"
        }
    }

    var distanceLabel: String {
        switch self {
        case .metric: return "km"
        case .imperial: return "mi"
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
