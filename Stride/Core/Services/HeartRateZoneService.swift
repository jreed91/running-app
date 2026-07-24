import Foundation

// MARK: - HRZone

/// A five-zone heart-rate model expressed as fractions of the runner's max HR.
/// Standard % of max-HR bands (Z1 50–60 … Z5 90–100). Readings below Z1's floor
/// (warm-up walking) clamp into Z1.
enum HRZone: Int, CaseIterable, Sendable, Identifiable {
    case z1 = 1, z2, z3, z4, z5

    var id: Int { rawValue }

    /// Short label, e.g. "Z3".
    var shortName: String { "Z\(rawValue)" }

    /// Human description of the training effect of the zone.
    var label: String {
        switch self {
        case .z1: return "Recovery"
        case .z2: return "Easy"
        case .z3: return "Aerobic"
        case .z4: return "Threshold"
        case .z5: return "Max"
        }
    }

    /// Inclusive lower bound as a fraction of max HR.
    var lowerFraction: Double {
        switch self {
        case .z1: return 0.50
        case .z2: return 0.60
        case .z3: return 0.70
        case .z4: return 0.80
        case .z5: return 0.90
        }
    }

    /// Exclusive upper bound as a fraction of max HR (Z5 is open-ended, capped at 1.0 for display).
    var upperFraction: Double {
        switch self {
        case .z1: return 0.60
        case .z2: return 0.70
        case .z3: return 0.80
        case .z4: return 0.90
        case .z5: return 1.00
        }
    }
}

// MARK: - HRZoneSlice

/// Time spent in a single zone, used as a chart datum.
struct HRZoneSlice: Identifiable, Sendable, Hashable {
    let zone: HRZone
    var seconds: Double
    var id: Int { zone.rawValue }
}

// MARK: - HeartRateZoneService

/// Pure heart-rate-zone math: classify readings, derive display bounds, and distribute a
/// run's duration across zones from its bpm sample series. No persistence or UI so it is
/// fully unit-testable (A6).
enum HeartRateZoneService {

    /// Classify a single bpm reading into a zone given max HR. Sub-Z1 readings clamp to Z1.
    static func zone(forBPM bpm: Double, maxHR: Double) -> HRZone {
        guard maxHR > 0 else { return .z1 }
        switch bpm / maxHR {
        case ..<0.60: return .z1
        case ..<0.70: return .z2
        case ..<0.80: return .z3
        case ..<0.90: return .z4
        default:      return .z5
        }
    }

    /// Lower/upper bpm bounds for a zone, rounded for display.
    static func bounds(for zone: HRZone, maxHR: Double) -> (lower: Int, upper: Int) {
        (
            lower: Int((zone.lowerFraction * maxHR).rounded()),
            upper: Int((zone.upperFraction * maxHR).rounded())
        )
    }

    /// Distribute a run's duration across zones from its bpm sample series. Samples are stored
    /// without per-sample timestamps, so each valid sample is assumed to represent an equal
    /// slice of the run (true for Apple Watch ~5 s sampling and the app's live collection).
    /// Returns a slice for every zone in order — including zeros — so charts stay stable.
    static func timeInZones(bpmSamples: [Double], totalSeconds: Double, maxHR: Double) -> [HRZoneSlice] {
        guard maxHR > 0, totalSeconds > 0, !bpmSamples.isEmpty else {
            return HRZone.allCases.map { HRZoneSlice(zone: $0, seconds: 0) }
        }
        let slice = totalSeconds / Double(bpmSamples.count)
        var seconds: [HRZone: Double] = [:]
        for bpm in bpmSamples where bpm > 0 {
            seconds[zone(forBPM: bpm, maxHR: maxHR), default: 0] += slice
        }
        return HRZone.allCases.map { HRZoneSlice(zone: $0, seconds: seconds[$0] ?? 0) }
    }

    /// Merge multiple per-run distributions into one aggregate (for the Progress tab).
    static func aggregate(_ distributions: [[HRZoneSlice]]) -> [HRZoneSlice] {
        var seconds: [HRZone: Double] = [:]
        for dist in distributions {
            for s in dist { seconds[s.zone, default: 0] += s.seconds }
        }
        return HRZone.allCases.map { HRZoneSlice(zone: $0, seconds: seconds[$0] ?? 0) }
    }
}
