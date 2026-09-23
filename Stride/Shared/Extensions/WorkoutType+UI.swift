import SwiftUI

extension WorkoutType {
    /// Stride Design System icon for this workout type.
    var strideIcon: StrideIconName {
        switch self {
        case .easy:          return .walk
        case .tempo:         return .tempo
        case .interval:      return .bolt
        case .longRun:       return .run
        case .race:          return .trophy
        case .rest:          return .moon
        case .crossTraining: return .dumbbell
        case .strength:      return .barbell
        // Not `.walk`: that glyph is already `.easy`'s, and a walk in the history list
        // has to be told apart from an easy run at a glance. The tortoise is the set's
        // "deliberately slow" mark, which is what a walk is.
        case .walk:          return .tortoise
        }
    }

    /// SF Symbol name for surfaces that can't use `StrideIcon` (widgets, App Intents).
    /// Derived from `strideIcon` so the two can't drift: the old hand-kept list showed
    /// an easy run and a walk with the same walking figure.
    var icon: String {
        strideIcon.systemSymbol ?? "figure.run"
    }

    /// Tint color for this workout type.
    var color: Color {
        switch self {
        case .easy, .longRun:  return .zoneEasy
        case .tempo:           return .zoneTempo
        case .interval, .race: return .zoneInterval
        case .strength:        return .brand
        case .walk:            return .zoneRecovery
        default:               return .secondary
        }
    }
}
