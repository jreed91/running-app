import Foundation

// MARK: - SpokenMetric

/// How a metric cell's value should be *heard* rather than read.
///
/// The app renders metrics as a big number plus a tight abbreviation ("142" / "bpm",
/// "5:12" / "/km"), which VoiceOver speaks literally — "142 b p m", "5:12 slash km" — and
/// speaks placeholders as a run of dashes. The run HUD fixed this for its own grid (N18);
/// this is the same rule with one home, so the run detail stats, the Progress period
/// summary, and any future metric cell all sound the same.
enum SpokenMetric {

    /// The spoken form of a metric: `nil`/placeholder values become "No data yet" and
    /// abbreviated units are spelled out.
    ///
    /// Unrecognised units are passed through unchanged — a unit already written in words
    /// ("minutes", "sets") needs no translation, and a new abbreviation reads no worse
    /// than it looks.
    static func spoken(value: String, unit: String? = nil) -> String {
        guard !isPlaceholder(value) else { return "No data yet" }
        guard let unit, !unit.isEmpty else { return value }
        return "\(value) \(spokenUnit(unit))"
    }

    /// The spoken form of a value that already carries its unit inline — "5.2 km",
    /// "142 bpm", "4:32 min/km" — which is how the Progress period summary and the
    /// history rows render theirs.
    ///
    /// Only a recognised trailing unit is translated; anything else is spoken as written,
    /// so a value that is already a sentence is left alone.
    static func spoken(measurement: String) -> String {
        guard !isPlaceholder(measurement) else { return "No data yet" }
        let parts = measurement.split(separator: " ")
        guard parts.count >= 2, let unit = parts.last else { return measurement }
        let translated = spokenUnit(String(unit))
        guard translated != String(unit) else { return measurement }
        return parts.dropLast().joined(separator: " ") + " " + translated
    }

    /// Whether a rendered value is one of the app's "nothing to show" placeholders.
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.allSatisfy { $0 == "-" || $0 == ":" }
    }

    private static func spokenUnit(_ unit: String) -> String {
        switch unit {
        case "spm":            return "steps per minute"
        case "bpm":            return "beats per minute"
        case "m":              return "metres"
        case "ft":             return "feet"
        case "km":             return "kilometres"
        case "mi":             return "miles"
        case "/km":            return "per kilometre"
        case "/mi":            return "per mile"
        case "min/km":         return "minutes per kilometre"
        case "min/mi":         return "minutes per mile"
        case "min":            return "minutes"
        case "%":              return "percent"
        default:               return unit
        }
    }
}
