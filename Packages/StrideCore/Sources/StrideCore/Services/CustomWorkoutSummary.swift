import Foundation

// MARK: - CustomWorkoutSummary

/// The one-line descriptions of a custom workout that the library and the builder show
/// (Custom workouts, PR 2): "6 × 800 m + 4 × 200 m" and "About 45 min · 8.1 km".
enum CustomWorkoutSummary {

    /// The main sets, joined: "6 × 800 m", "3 × 1 mi + 4 × 1:00". Empty for no sets.
    static func setsLine(_ structure: WorkoutStructure, unit: UnitPreference) -> String {
        structure.mainSets.compactMap { set in
            guard let amount = amount(set.workSegment, unit: unit) else { return nil }
            return set.repetitions > 1 ? "\(set.repetitions) × \(amount)" : amount
        }
        .joined(separator: " + ")
    }

    /// "About 45 min · 8.1 km" from the stored totals, or `nil` when there are none.
    static func totalsLine(_ structure: WorkoutStructure, unit: UnitPreference) -> String? {
        let seconds = structure.totalEstimatedDurationSeconds
        let meters = structure.totalEstimatedDistanceMeters
        guard seconds > 0 else { return nil }
        let minutes = max(1, Int((seconds / 60).rounded()))
        let time = String(localized: "About \(minutes) min", comment: "Custom workout estimated duration")
        guard meters > 0 else { return time }
        return "\(time) · \(meters.distanceString(unit: unit))"
    }

    /// "800 m", "1 mi", "1.5 km", "1:30".
    static func amount(_ segment: WorkoutSegment, unit: UnitPreference) -> String? {
        if let meters = segment.distanceMeters, meters > 0 {
            let display = CustomWorkoutDistanceUnit.display(for: meters, unit: unit)
            return "\(number(meters / display.metersPerUnit)) \(display.symbol)"
        }
        if let seconds = segment.durationSeconds, seconds > 0 {
            return seconds.durationString
        }
        return nil
    }

    /// Up to two decimals, no trailing zeros: "800", "1.5", "0.25".
    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.2f", rounded)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
}
