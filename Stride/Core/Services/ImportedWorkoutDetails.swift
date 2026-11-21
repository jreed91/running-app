import Foundation

// MARK: - ImportedWorkoutDetails

/// What Apple Health knows about a strength workout that came from the Watch or another
/// app, for the strength summary of a session Stride has no sets for.
///
/// Read from Health when the summary opens rather than stored: keeping any of it on
/// `StrengthWorkout` would be a new stored property and so a CloudKit schema deployment,
/// and Health keeps it anyway. Gone when the workout is, which is when there would be
/// nothing to say about it.
struct ImportedWorkoutDetails: Equatable, Sendable {

    /// The kind of session, as Health files it.
    enum Kind: String, Equatable, Sendable {
        case traditionalStrength
        case functionalStrength
        case core
        case other
    }

    let kind: Kind
    /// The app or device that recorded it ("Workout", "Fitbod"...), when Health names one.
    let sourceName: String?
    let averageHeartRate: Double?

    /// The session's title, in place of the plan focus a Stride session takes its from.
    var title: String {
        switch kind {
        case .traditionalStrength: return String(localized: "Strength Training", comment: "Imported strength workout title")
        case .functionalStrength: return String(localized: "Functional Strength", comment: "Imported strength workout title")
        case .core: return String(localized: "Core Training", comment: "Imported strength workout title")
        case .other: return String(localized: "Strength Workout", comment: "Imported strength workout title")
        }
    }

    /// Average heart rate as the summary shows it, or nil when Health has none.
    var heartRateText: String? {
        guard let bpm = averageHeartRate, bpm >= 1 else { return nil }
        return "\(Int(bpm.rounded())) bpm"
    }

    /// The source as the summary says it, or nil for Stride's own export, which is not
    /// "another app".
    var recordedByText: String? {
        guard let name = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              name.range(of: "Stride", options: .caseInsensitive) == nil
        else { return nil }
        return String(localized: "Recorded by \(name)", comment: "Source app of an imported strength workout")
    }
}
