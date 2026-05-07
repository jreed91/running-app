import Foundation

// MARK: - RaceType

enum RaceType: String, Codable, CaseIterable, Sendable {
    case maintainFitness = "Maintain Fitness"
    case fiveK = "5K"
    case halfMarathon = "Half Marathon"
    case marathon = "Marathon"

    var displayName: String { rawValue }

    var isGoalRace: Bool {
        self != .maintainFitness
    }

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
            case .beginner:     return 12
            case .intermediate: return 20
            case .advanced:     return 30
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
    case strength = "Strength"

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

// MARK: - WorkoutLocation

enum WorkoutLocation: String, Codable, CaseIterable, Sendable {
    case outdoor = "Outdoor"
    case indoor = "Indoor"

    var displayName: String { rawValue }

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


// MARK: - AIProvider

enum AIProvider: String, CaseIterable, Sendable {
    case openAI = "openai"
    case anthropic = "anthropic"

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Claude (Anthropic)"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-3-5-sonnet-latest"
        }
    }
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

    var subtitle: String {
        switch self {
        case .runningSpecific: return "Glutes, hips, core, and single-leg stability"
        case .generalStrength: return "Full-body strength with push, pull, and hinge patterns"
        }
    }
}
