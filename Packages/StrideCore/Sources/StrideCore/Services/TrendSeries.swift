import Foundation

// MARK: - TrendSeries

/// The Progress page's trend charts (heart rate, elevation, VDOT) reduced to one point
/// per week or month, and the date axis to draw them on.
///
/// Those charts drew a mark per run. On a month that is a dozen; on "All" after a
/// five-year import it was a thousand-odd marks, an axis label per month that piled
/// into an unreadable smear, and a page slow enough to hang. A week or month is the
/// grain the page's own filter already uses, so the charts now follow
/// `ProgressFilter.Period.grouping` like the volume chart above them.
///
/// Pure and `Sendable`, like `VolumeExplorer`, whose calendar and grouping it reuses.
public enum TrendSeries {

    // MARK: Plausible values

    /// Average paces outside this are a recording fault (a run left going in a bag, a
    /// GPS glitch over a few metres), not a run: 2:30 to 20:00 per km.
    public static let plausiblePaceSecondsPerKm: ClosedRange<Double> = 150...1_200

    /// Average heart rates outside this are a strap that dropped out, not a run.
    public static let plausibleHeartRate: ClosedRange<Double> = 70...230

    // MARK: Buckets

    public struct Point: Equatable, Sendable {
        public let date: Date
        public let value: Double

        public init(
            date: Date,
            value: Double
        ) {
            self.date = date
            self.value = value
        }
    }

    public enum Statistic: Sendable {
        /// The mean of the period's values: average heart rate.
        case mean
        /// The median, so one hilly or windy run doesn't drag it: easy pace.
        case median
        /// The total: elevation gained.
        case sum
        /// The highest: the best VDOT the period showed.
        case max
    }

    public struct Bucket: Equatable, Sendable, Identifiable {
        /// Start of the week or month.
        public let start: Date
        /// The mean time of the period's values, where the chart places the point, so
        /// it sits among the runs it summarises and never past today.
        public let plotDate: Date
        public let value: Double
        /// How many values the period had.
        public let count: Int

        public var id: Date { start }

        public init(
            start: Date,
            plotDate: Date,
            value: Double,
            count: Int
        ) {
            self.start = start
            self.plotDate = plotDate
            self.value = value
            self.count = count
        }
    }

    /// One bucket per week or month that has a value, oldest first.
    public static func buckets(
        _ points: [Point],
        grouping: VolumeExplorer.Grouping,
        statistic: Statistic,
        calendar: Calendar = VolumeExplorer.calendar()
    ) -> [Bucket] {
        let grouped = Dictionary(grouping: points) {
            VolumeExplorer.periodStart(of: $0.date, grouping: grouping, calendar: calendar)
        }
        return grouped.compactMap { start, members -> Bucket? in
            let values = members.map(\.value)
            guard let value = reduce(values, statistic) else { return nil }
            let meanTime = members.reduce(0) { $0 + $1.date.timeIntervalSinceReferenceDate } / Double(members.count)
            return Bucket(
                start: start,
                plotDate: Date(timeIntervalSinceReferenceDate: meanTime),
                value: value,
                count: members.count
            )
        }
        .sorted { $0.start < $1.start }
    }

    /// The bucket nearest `date`, for a chart's selection.
    public static func nearest(to date: Date, in buckets: [Bucket]) -> Bucket? {
        buckets.min { abs($0.plotDate.timeIntervalSince(date)) < abs($1.plotDate.timeIntervalSince(date)) }
    }

    public static func reduce(_ values: [Double], _ statistic: Statistic) -> Double? {
        guard !values.isEmpty else { return nil }
        switch statistic {
        case .mean: return values.reduce(0, +) / Double(values.count)
        case .sum: return values.reduce(0, +)
        case .max: return values.max()
        case .median:
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
    }

    // MARK: Date axis

    /// How a time axis is labelled.
    public struct DateAxis: Equatable, Sendable {
        public enum Unit: Sendable { case month, year }
        public enum Label: Sendable {
            /// "Mar"
            case month
            /// "Mar 25", for a span that crosses a new year but isn't years long.
            case monthYear
            /// "2025"
            case year
        }

        public let unit: Unit
        public let count: Int
        public let label: Label

        public init(
            unit: Unit,
            count: Int,
            label: Label
        ) {
            self.unit = unit
            self.count = count
            self.label = label
        }
    }

    /// At most about six labels whatever the span: monthly up to half a year, every
    /// few months up to two years, then yearly (every other year past six).
    public static func dateAxis(from start: Date, to end: Date, calendar: Calendar = VolumeExplorer.calendar()) -> DateAxis {
        let months = max(0, calendar.dateComponents([.month], from: start, to: end).month ?? 0)
        switch months {
        case ..<7: return DateAxis(unit: .month, count: 1, label: .month)
        case ..<13: return DateAxis(unit: .month, count: 2, label: .month)
        case ..<25: return DateAxis(unit: .month, count: 6, label: .monthYear)
        case ..<73: return DateAxis(unit: .year, count: 1, label: .year)
        default: return DateAxis(unit: .year, count: Int((Double(months) / 72).rounded(.up)), label: .year)
        }
    }
}
