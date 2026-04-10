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

    /// Approximate starting weekly mileage in km
    var startingWeeklyKm: Double {
        switch self {
        case .beginner: return 20
        case .intermediate: return 40
        case .advanced: return 65
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
