import Foundation

// MARK: - ChartAccessibility

/// Builds the sentence VoiceOver speaks for a chart.
///
/// A SwiftUI `Chart` exposes its marks as unlabelled sub-elements, so swiping through one
/// reads as a run of anonymous values — or, with a selection overlay, as nothing at all.
/// Every chart in the app was in that state (N18 / D8): the pace trend, HR trend,
/// elevation, weekly volume, VO₂-max, zone distribution, race predictions, and the three
/// split charts.
///
/// The summary is deliberately short and always the same shape, so it is quick to hear
/// and quick to compare between charts: how many values there are, where the series
/// starts and ends, and its extremes. Formatting is the caller's, so a pace chart speaks
/// "4:32 per kilometre" while a volume chart speaks "42.1 km".
enum ChartAccessibility {

    /// One plotted value: the label of the thing it was measured on (a date, a split
    /// number, a zone) and the value itself, unformatted.
    struct Point: Sendable, Equatable {
        var label: String
        var value: Double

        init(label: String, value: Double) {
            self.label = label
            self.value = value
        }
    }

    /// A chart's whole accessible payload: the points, how a value is spoken, and what the
    /// value axis is called.
    ///
    /// The summary alone was enough while a chart was one collapsed element. An **Audio
    /// Graph** needs more — the series itself, so VoiceOver can play it as sound and step
    /// through it point by point — and it needs exactly the same numbers and the same
    /// formatter the summary uses, or the two would disagree about the chart in front of
    /// them (U10). Passing this instead of a pre-built `String` is what keeps them one
    /// thing.
    struct Series {
        var points: [Point]
        /// Name of the value axis, e.g. "Pace" or "Distance". Spoken when a VoiceOver user
        /// asks what the graph's axes are.
        var valueAxisLabel: String
        /// Renders one value the way the chart's axis does, units included.
        var format: (Double) -> String

        init(points: [Point], valueAxisLabel: String, format: @escaping (Double) -> String) {
            self.points = points
            self.valueAxisLabel = valueAxisLabel
            self.format = format
        }

        /// The sentence VoiceOver speaks as the chart's value.
        var summary: String {
            ChartAccessibility.summary(points, format: format)
        }
    }

    /// What a chart's data sounds like: count, endpoints, and extremes.
    ///
    /// Points are read in the order given — chronological for a trend chart, ascending
    /// bucket order for splits — since "from … to …" is only meaningful along the axis the
    /// chart itself draws.
    ///
    /// - Parameters:
    ///   - points: the plotted values, in the order the chart draws them.
    ///   - format: renders one value the way the chart's axis does, units included.
    static func summary(_ points: [Point], format: (Double) -> String) -> String {
        guard let first = points.first, let last = points.last else {
            return String(localized: "No data", comment: "Spoken summary of an empty chart")
        }
        guard points.count > 1 else {
            return String(localized: "1 value: \(first.label), \(format(first.value)).", comment: "Spoken summary of a chart with one point")
        }

        var sentences = [
            String(localized: "\(points.count) values.", comment: "How many points a chart has"),
            String(localized: "From \(first.label), \(format(first.value)) to \(last.label), \(format(last.value)).", comment: "Where a charted series starts and ends")
        ]
        // Endpoints are often the extremes too; naming them again is a little redundant
        // but keeps every chart's summary the same shape, which matters more when it is
        // heard rather than read.
        if let lowest = points.min(by: { $0.value < $1.value }),
           let highest = points.max(by: { $0.value < $1.value }),
           lowest.value < highest.value {
            sentences.append(String(localized: "Lowest \(lowest.label), \(format(lowest.value)).", comment: "A charted series' minimum"))
            sentences.append(String(localized: "Highest \(highest.label), \(format(highest.value)).", comment: "A charted series' maximum"))
        }
        return sentences.joined(separator: " ")
    }
}
