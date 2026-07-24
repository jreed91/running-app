import SwiftUI

extension HRZone {
    /// Cool→warm colour ramp reusing the app's pace-zone palette so HR zones read consistently
    /// with the rest of the app (Z1 recovery blue … Z5 interval red).
    var color: Color {
        switch self {
        case .z1: return .zoneRecovery
        case .z2: return .zoneEasy
        case .z3: return .zoneMarathon
        case .z4: return .zoneTempo
        case .z5: return .zoneInterval
        }
    }

    /// "Z3 · Aerobic" style caption.
    var displayTitle: String { "\(shortName) · \(label)" }
}
