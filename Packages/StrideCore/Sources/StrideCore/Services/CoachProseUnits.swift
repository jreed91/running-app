import Foundation

// MARK: - CoachProseUnits

/// Rewrites the paces and distances in coach-written prose into the runner's unit.
///
/// The adaptation schema's numeric pace fields are seconds per kilometre whatever the
/// runner's unit, so the model works in kilometres and writes its explanation the same
/// way: a runner who reads miles got "You need to slow this run to 6:40–7:40 per km" in
/// the workout's notes, under a card that says "3.1 mi". Asking the model to convert in
/// its head would swap a wrong unit for a wrong number, so it keeps writing what it
/// computed and this rewrites the figures afterwards.
///
/// Only a number followed by a unit is touched. "The fourth kilometre", "a 5K", "36 min"
/// and anything already in the runner's unit are left as written.
enum CoachProseUnits {

    static func localized(_ text: String, to unit: UnitPreference) -> String {
        let source: SourceUnit = unit == .imperial ? .kilometres : .miles
        // Paces first: once "6:40 per km" is "10:44 per mile" there is no number left in
        // front of a unit for the distance pass to misread.
        return convertDistances(in: convertPaces(in: text, from: source), from: source)
    }

    // MARK: Paces

    /// "6:40 per km", "6:40–7:40 per km", "6:40 to 7:40 /km".
    private static func convertPaces(in text: String, from source: SourceUnit) -> String {
        let pattern = #"(\d{1,2}):([0-5]\d)(?:(\s*[–—-]\s*|\s+to\s+)(\d{1,2}):([0-5]\d))?(\s*)("#
            + source.pacePhrase + #")\b"#
        return replacingMatches(of: pattern, in: text) { groups in
            guard let first = convertedPace(minutes: groups[1], seconds: groups[2], from: source),
                  let phrase = groups[7] else { return nil }
            var replacement = first
            if let separator = groups[3] {
                guard let second = convertedPace(minutes: groups[4], seconds: groups[5], from: source) else {
                    return nil
                }
                replacement += separator + second
            }
            replacement += (groups[6] ?? "") + source.targetPacePhrase(replacing: phrase)
            return replacement
        }
    }

    private static func convertedPace(minutes: String?, seconds: String?, from source: SourceUnit) -> String? {
        guard let minutes = minutes.flatMap(Int.init), let seconds = seconds.flatMap(Int.init) else {
            return nil
        }
        let total = Int((Double(minutes * 60 + seconds) * source.paceFactor).rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    // MARK: Distances

    /// "5 km", "8.5 kilometres". The lookbehind keeps "6:40 km" from reading as 40 km.
    private static func convertDistances(in text: String, from source: SourceUnit) -> String {
        let pattern = #"(?<![\d:.,])(\d+(?:\.\d+)?)(\s?)("# + source.distanceWord + #")\b"#
        return replacingMatches(of: pattern, in: text) { groups in
            guard let value = groups[1].flatMap(Double.init), let word = groups[3] else { return nil }
            let converted = String(format: "%.1f", value * source.distanceFactor)
            return converted + (groups[2] ?? "") + source.targetDistanceWord(replacing: word, value: converted)
        }
    }

    // MARK: Matching

    /// Replaces every match of `pattern`, case-insensitively, with what `transform` builds
    /// from its capture groups (`nil` for a group that did not take part). A `nil` from
    /// `transform` leaves that match as written.
    private static func replacingMatches(
        of pattern: String,
        in text: String,
        transform: ([String?]) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let source = text as NSString
        let result = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        // Back to front, so each replacement leaves the earlier ranges where they were.
        for match in matches.reversed() {
            let groups: [String?] = (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            guard let replacement = transform(groups) else { continue }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    // MARK: Units

    /// The unit the prose was written in: the one the runner does *not* use.
    private enum SourceUnit {
        case kilometres
        case miles

        private static let metresPerMile = 1_609.344

        var pacePhrase: String {
            switch self {
            case .kilometres: return #"per\s+(?:km|kilomet(?:re|er))|/\s?km"#
            case .miles:      return #"per\s+(?:mi|mile)|/\s?mi"#
            }
        }

        var distanceWord: String {
            switch self {
            case .kilometres: return #"km|kilomet(?:re|er)s?"#
            case .miles:      return #"mi|miles?"#
            }
        }

        /// Seconds per source unit → seconds per target unit.
        var paceFactor: Double {
            switch self {
            case .kilometres: return Self.metresPerMile / 1_000
            case .miles:      return 1_000 / Self.metresPerMile
            }
        }

        /// Source distance → target distance.
        var distanceFactor: Double { 1 / paceFactor }

        /// Keeps the shape the model used: "/km" becomes "/mi", "per km" becomes "per mile".
        func targetPacePhrase(replacing phrase: String) -> String {
            let isSlash = phrase.hasPrefix("/")
            switch self {
            case .kilometres: return isSlash ? "/mi" : "per mile"
            case .miles:      return isSlash ? "/km" : "per km"
            }
        }

        func targetDistanceWord(replacing word: String, value: String) -> String {
            switch self {
            case .kilometres:
                if word.lowercased() == "km" { return "mi" }
                return value == "1.0" ? "mile" : "miles"
            case .miles:
                return "km"
            }
        }
    }
}
