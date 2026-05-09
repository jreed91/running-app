import SwiftUI

extension WorkoutType {
    /// Stride Design System icon for this workout type.
    var strideIcon: StrideIconName {
        switch self {
        case .easy:          return .shoe
        case .tempo:         return .flame
        case .interval:      return .bolt
        case .longRun:       return .road
        case .race:          return .flag
        case .rest:          return .moon
        case .crossTraining: return .dumbbell
        case .strength:      return .barbell
        }
    }

    /// Legacy SF Symbol name — kept for any views not yet migrated to StrideIcon.
    var icon: String {
        switch self {
        case .easy:          return "figure.walk"
        case .tempo:         return "gauge.with.needle"
        case .interval:      return "bolt.fill"
        case .longRun:       return "figure.run"
        case .race:          return "trophy"
        case .rest:          return "moon.zzz"
        case .crossTraining: return "dumbbell"
        case .strength:      return "figure.strengthtraining.traditional"
        }
    }

    /// Tint color for this workout type.
    var color: Color {
        switch self {
        case .easy, .longRun:  return .zoneEasy
        case .tempo:           return .zoneTempo
        case .interval, .race: return .zoneInterval
        case .strength:        return .brand
        default:               return .secondary
        }
    }
}
