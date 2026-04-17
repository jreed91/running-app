import SwiftUI

extension WorkoutType {
    /// SF Symbol name for this workout type.
    var icon: String {
        switch self {
        case .easy:          return "figure.run"
        case .tempo:         return "gauge.with.needle"
        case .interval:      return "repeat"
        case .longRun:       return "arrow.right.to.line"
        case .race:          return "trophy"
        case .rest:          return "moon.zzz"
        case .crossTraining: return "bicycle"
        }
    }

    /// Tint color for this workout type.
    var color: Color {
        switch self {
        case .easy, .longRun:  return .zoneEasy
        case .tempo:           return .zoneTempo
        case .interval, .race: return .zoneInterval
        default:               return .secondary
        }
    }
}
