import SwiftUI

// MARK: - PaceZone

enum PaceZone: String {
    case recovery = "Recovery"
    case easy = "Easy"
    case marathon = "Marathon"
    case tempo = "Tempo"
    case interval = "Interval"
    case maxEffort = "Max Effort"

    var color: Color {
        switch self {
        case .recovery:  .zoneRecovery
        case .easy:      .zoneEasy
        case .marathon:  .zoneMarathon
        case .tempo:     .zoneTempo
        case .interval:  .zoneInterval
        case .maxEffort: .zoneMax
        }
    }

    var systemImage: String {
        switch self {
        case .recovery:  "tortoise.fill"
        case .easy:      "figure.walk"
        case .marathon:  "figure.run"
        case .tempo:     "gauge.medium"
        case .interval:  "bolt.fill"
        case .maxEffort: "flame.fill"
        }
    }

    var strideIcon: StrideIconName {
        switch self {
        case .recovery:  return .tortoise
        case .easy:      return .walk
        case .marathon:  return .run
        case .tempo:     return .tempo
        case .interval:  return .bolt
        case .maxEffort: return .flame
        }
    }
}

// MARK: - Zone classification

extension PaceZone {
    /// Determines which zone a given pace falls into.
    /// - Parameters:
    ///   - pace: Current pace in seconds per km (higher = slower).
    ///   - paces: Training paces derived from the runner's VDOT.
    static func zone(for pace: Double, using paces: TrainingPaces) -> PaceZone {
        guard pace > 0 else { return .recovery }

        if pace > paces.easyRange.upperBound {
            return .recovery
        } else if pace >= paces.easyRange.lowerBound {
            return .easy
        } else if pace > paces.threshold * 1.05 {
            return .marathon
        } else if pace >= paces.threshold * 0.95 {
            return .tempo
        } else if pace >= paces.interval * 0.95 {
            return .interval
        } else {
            return .maxEffort
        }
    }
}

// MARK: - View

struct PaceZoneIndicator: View {
    let currentPace: Double       // seconds/km; 0 means no signal yet
    let paces: TrainingPaces

    private var zone: PaceZone {
        PaceZone.zone(for: currentPace, using: paces)
    }

    var body: some View {
        HStack(spacing: 10) {
            StrideIcon(name: zone.strideIcon, size: 18, color: zone.color, strokeWeight: 2.0)

            Text(zone.rawValue.uppercased())
                .font(.sectionHeader)
                .foregroundStyle(zone.color)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(zone.color.opacity(0.15), in: Capsule())
        .animation(.easeInOut(duration: 0.3), value: zone.rawValue)
    }
}
