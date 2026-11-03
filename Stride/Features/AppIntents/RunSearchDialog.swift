import Foundation

/// What Siri says after the "find runs" tool (`FindRunsIntent`, iOS 27.3 SDK only).
/// Kept outside that gated file so the wording is unit-tested on every Xcode.
enum RunSearchDialog {
    static func text(count: Int, totalMeters: Double, unit: UnitPreference) -> String {
        switch count {
        case 0:
            return String(localized: "No runs match that.", comment: "Siri answer when a run search finds nothing")
        case 1:
            let total = totalMeters.distanceString(unit: unit)
            return String(localized: "Found 1 run, \(total).", comment: "Siri answer when a run search finds one run")
        default:
            let total = totalMeters.distanceString(unit: unit)
            return String(
                localized: "Found \(count) runs, \(total) in total.",
                comment: "Siri answer when a run search finds several runs"
            )
        }
    }
}
