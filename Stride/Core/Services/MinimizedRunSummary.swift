import Foundation

// MARK: - MinimizedRunSummary

/// What a minimised run says above the tab bar, in words.
///
/// The tab-bar accessory is one line tall and is the only thing a runner sees of a
/// recording run while they are somewhere else in the app (U7), so the wording carries
/// more than it looks: it has to state *that* the run is still going, how long it has
/// been going, and — because the accessory is the affordance for getting back — it has
/// to say so to VoiceOver as well as on screen.
///
/// Pure and `Sendable`, like the app's other presentation rules (`SpokenMetric`,
/// `ChartAccessibility`), so the wording is testable without a running tracker.
enum MinimizedRunSummary {

    /// The single line the accessory shows: elapsed time and distance, prefixed with the
    /// paused state when the run is holding.
    ///
    /// Paused is spelled out rather than left to the play/pause glyph beside it: a
    /// glyph-only difference is exactly what Differentiate Without Color and a glance
    /// mid-stride lose (U3d).
    static func title(
        state: TrackingState,
        elapsedSeconds: Double,
        distanceMeters: Double,
        unit: UnitPreference
    ) -> String {
        let metrics = "\(elapsedSeconds.durationString) · \(distanceMeters.distanceString(unit: unit))"
        guard state == .paused else { return metrics }
        return String(
            localized: "Paused · \(metrics)",
            comment: "Minimised-run accessory title while the run is paused"
        )
    }

    /// The VoiceOver label for the same row.
    ///
    /// `title` is built for a glance — abbreviated units, a middle dot separator — which
    /// VoiceOver reads literally ("27:14 dot 5.2 k m"). This says the same thing in
    /// words, using the same spoken-unit table as every other metric in the app.
    static func spokenLabel(
        state: TrackingState,
        elapsedSeconds: Double,
        distanceMeters: Double,
        unit: UnitPreference
    ) -> String {
        let status = state == .paused
            ? String(localized: "Run paused", comment: "VoiceOver status of the minimised run accessory")
            : String(localized: "Run in progress", comment: "VoiceOver status of the minimised run accessory")
        let elapsed = String(
            localized: "\(elapsedSeconds.durationString) elapsed",
            comment: "VoiceOver elapsed time in the minimised run accessory"
        )
        let distance = SpokenMetric.spoken(measurement: distanceMeters.distanceString(unit: unit))
        return "\(status). \(elapsed), \(distance)"
    }
}
