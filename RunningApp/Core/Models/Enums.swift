import Foundation

// MARK: - RaceType

enum RaceType: String, Codable, CaseIterable, Sendable {
    case fiveK = "5K"
    case halfMarathon = "Half Marathon"

    var displayName: String { rawValue }

    var distanceMeters: Double {
        switch self {
        case .fiveK: return 5_000
        case .halfMarathon: return 21_097.5
        }
    }

    var typicalWeeks: ClosedRange<Int> {
        switch self {
        case .fiveK: return 8...12
        case .halfMarathon: return 12...20
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
        case .fiveK:
            switch self {
            case .beginner:     return 15   // ~9 mi/wk
            case .intermediate: return 25   // ~15 mi/wk
            case .advanced:     return 40   // ~25 mi/wk
            }
        case .halfMarathon:
            switch self {
            case .beginner:     return 25   // ~15 mi/wk
            case .intermediate: return 40   // ~25 mi/wk
            case .advanced:     return 60   // ~37 mi/wk
            }
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
        case .metric: return "/km"
        case .imperial: return "/mi"
        }
    }
}
