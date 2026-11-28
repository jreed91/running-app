import Foundation

// In its own file so `StrideWatch` can compile it with the spoken-cue wording
// (`SplitAnnouncement`, `GuidedStepAnnouncement`) without the rest of `Enums.swift`,
// which reaches into the app's SwiftUI icon types (Watch runs, PR 4).

// MARK: - UnitPreference

public enum UnitPreference: String, CaseIterable, Sendable {
    case metric = "metric"
    case imperial = "imperial"

    /// What this device already measures in, used when the runner has never chosen.
    ///
    /// Onboarding used to spend a whole step of nine asking this (U10), with `.metric`
    /// as the answer it assumed if you skipped — wrong for every runner in the US.
    /// The system already knows, so the step became a control on the "About you" step
    /// instead of a question of its own.
    ///
    /// Anything that is not the metric system maps to miles: `.uk` measures road
    /// distance in miles, which is the only measurement this app makes.
    public static var localeDefault: UnitPreference {
        Locale.current.measurementSystem == .metric ? .metric : .imperial
    }

    public var displayName: String {
        switch self {
        case .metric: return "Kilometers"
        case .imperial: return "Miles"
        }
    }

    /// The name a runner reads. `displayName` is the canonical English form — it is what
    /// the AI prompts, the logs, and the seeded race names use, and several of those are
    /// compared or persisted, so it must not move with the device language (D8).
    public var localizedName: String {
        switch self {
        case .metric:   return String(localized: "Kilometers", comment: "Unit preference")
        case .imperial: return String(localized: "Miles", comment: "Unit preference")
        }
    }

    public var distanceLabel: String {
        switch self {
        case .metric: return "km"
        case .imperial: return "mi"
        }
    }

    /// Uppercased distance label used as a split/segment header (e.g. "KM" / "MI").
    public var splitLabel: String { distanceLabel.uppercased() }

    /// Length in metres of one split bucket in this unit: 1 km or 1 mile.
    public var splitLengthMeters: Double {
        switch self {
        case .metric:   return 1_000
        case .imperial: return 1_609.344
        }
    }

    public var paceLabel: String {
        switch self {
        case .metric: return "min/km"
        case .imperial: return "min/mi"
        }
    }

    public var elevationLabel: String {
        switch self {
        case .metric:   return "m"
        case .imperial: return "ft"
        }
    }
}
