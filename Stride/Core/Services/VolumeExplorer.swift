import Foundation

// MARK: - VolumeExplorer

/// The arithmetic behind the volume explorer: how much running each week or month held,
/// over a window the runner picks, and how that window compares with the one before it.
///
/// The Progress card it opens from buckets only the weeks that had a run, so a week off
/// simply vanished from the chart and the bars either side of it sat together as if the
/// runner never stopped. The explorer is where a runner goes to read their training
/// history, so every period in the window gets a bucket, empty ones included.
///
/// Pure and `Sendable`. It takes ``Run`` values rather than `RunWorkout` models, so it can
/// be tested without SwiftData and the view decides which runs count.
enum VolumeExplorer {

    // MARK: Inputs

    /// What a bar measures.
    enum Metric: String, CaseIterable, Sendable {
        case distance
        case time
        case runs
        case climb
    }

    /// How wide a bar is.
    enum Grouping: String, CaseIterable, Sendable {
        case week
        case month

        var component: Calendar.Component {
            switch self {
            case .week: return .weekOfYear
            case .month: return .month
            }
        }
    }

    /// How far back the chart reaches.
    enum Window: String, CaseIterable, Sendable {
        case month = "1M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case year = "1Y"
        case all = "All"

        /// Calendar months the window spans, or `nil` for all time.
        var months: Int? {
            switch self {
            case .month: return 1
            case .threeMonths: return 3
            case .sixMonths: return 6
            case .year: return 12
            case .all: return nil
            }
        }

        /// Weeks read well up to half a year; past that there are too many bars to tap.
        var defaultGrouping: Grouping {
            switch self {
            case .month, .threeMonths, .sixMonths: return .week
            case .year, .all: return .month
            }
        }
    }

    /// One run, as much of it as the explorer reads.
    struct Run: Equatable, Sendable {
        let id: UUID
        let date: Date
        let meters: Double
        let seconds: Double
        /// `nil` when the run carried no elevation, which counts as no climb.
        let climbMeters: Double?
    }

    // MARK: Buckets

    /// One bar: a week or a month and what was run in it.
    struct Bucket: Equatable, Sendable, Identifiable {
        let start: Date
        /// Exclusive: the start of the next period.
        let end: Date
        var meters: Double = 0
        var seconds: Double = 0
        var climbMeters: Double = 0
        /// Oldest first, so the list under the chart reads in the order they were run.
        var runIDs: [UUID] = []

        var id: Date { start }
        var runCount: Int { runIDs.count }

        /// The bar's height, in base units: metres, seconds, runs or metres climbed.
        func value(_ metric: Metric) -> Double {
            switch metric {
            case .distance: return meters
            case .time: return seconds
            case .runs: return Double(runCount)
            case .climb: return climbMeters
            }
        }

        func contains(_ date: Date) -> Bool { date >= start && date < end }
    }

    /// The calendar the explorer counts in: weeks start on Monday, as `Date.startOfWeek`
    /// and every other weekly figure in the app do.
    static func calendar(base: Calendar = .current) -> Calendar {
        var calendar = base
        calendar.firstWeekday = 2
        return calendar
    }

    /// The start of the week or month that holds `date`.
    static func periodStart(of date: Date, grouping: Grouping, calendar: Calendar) -> Date {
        calendar.dateInterval(of: grouping.component, for: date)?.start ?? date
    }

    /// Where the window begins: whole calendar months back from `now`, or the first run
    /// for all time. With no runs at all, all time is just the current period.
    static func windowStart(
        _ window: Window,
        now: Date,
        earliestRun: Date?,
        calendar: Calendar
    ) -> Date {
        guard let months = window.months else {
            return min(earliestRun ?? now, now)
        }
        return calendar.date(byAdding: .month, value: -months, to: now) ?? now
    }

    /// Every week or month from the one holding `start` to the one holding `now`, each
    /// holding the runs that fell in it. Empty periods are kept, so a week off reads as a
    /// gap. Runs outside those periods are ignored.
    static func buckets(
        for runs: [Run],
        grouping: Grouping,
        from start: Date,
        through now: Date,
        calendar: Calendar
    ) -> [Bucket] {
        let first = periodStart(of: min(start, now), grouping: grouping, calendar: calendar)
        let last = periodStart(of: now, grouping: grouping, calendar: calendar)

        var buckets: [Bucket] = []
        var cursor = first
        // Bounded so a broken calendar can never spin forever: 20 years of weeks.
        while cursor <= last, buckets.count < 1_100 {
            guard let next = calendar.date(byAdding: grouping.component, value: 1, to: cursor),
                  next > cursor else { break }
            buckets.append(Bucket(start: cursor, end: next))
            cursor = next
        }
        guard let windowStart = buckets.first?.start, let windowEnd = buckets.last?.end else {
            return []
        }

        for run in runs.sorted(by: { $0.date < $1.date })
        where run.date >= windowStart && run.date < windowEnd {
            // Buckets are contiguous and sorted, so the index is a search, not a scan.
            guard let index = bucketIndex(for: run.date, in: buckets) else { continue }
            buckets[index].meters += max(0, run.meters)
            buckets[index].seconds += max(0, run.seconds)
            buckets[index].climbMeters += max(0, run.climbMeters ?? 0)
            buckets[index].runIDs.append(run.id)
        }
        return buckets
    }

    private static func bucketIndex(for date: Date, in buckets: [Bucket]) -> Int? {
        var low = 0
        var high = buckets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if buckets[mid].contains(date) { return mid }
            if date < buckets[mid].start { high = mid - 1 } else { low = mid + 1 }
        }
        return nil
    }

    /// The bucket nearest a chart selection, for turning a tap into a bar.
    static func bucket(nearest date: Date, in buckets: [Bucket]) -> Bucket? {
        if let index = bucketIndex(for: date, in: buckets) { return buckets[index] }
        return buckets.min { lhs, rhs in
            abs(lhs.start.timeIntervalSince(date)) < abs(rhs.start.timeIntervalSince(date))
        }
    }

    // MARK: Summary

    /// The headline over the chart.
    struct Summary: Equatable, Sendable {
        /// Sum over the window, in the metric's base unit.
        let total: Double
        /// Per bucket, empty buckets included, so a week off pulls the average down.
        let averagePerBucket: Double
        /// The biggest bucket, or `nil` when every bucket is empty.
        let best: Bucket?
        /// The same length of time just before the window, or `nil` for all time.
        let previousTotal: Double?

        /// Fractional change against the previous window: 0.12 is 12% more. `nil` when
        /// there is nothing to compare with, including a previous window with no running,
        /// where any percentage would be infinite.
        var change: Double? {
            guard let previousTotal, previousTotal > 0 else { return nil }
            return (total - previousTotal) / previousTotal
        }
    }

    static func summary(
        metric: Metric,
        runs: [Run],
        buckets: [Bucket],
        window: Window,
        now: Date
    ) -> Summary {
        let total = buckets.reduce(0) { $0 + $1.value(metric) }
        let best = buckets.max { $0.value(metric) < $1.value(metric) }

        var previousTotal: Double?
        if window.months != nil, let chartStart = buckets.first?.start, now > chartStart {
            // The same stretch of time, ending where the charted buckets begin: the chart
            // starts on a period boundary and ends today, part way through a period, so
            // the comparison takes that exact length rather than a round number of months.
            // Ending at the chart's start means the two totals never count a run twice.
            let previousStart = chartStart.addingTimeInterval(-now.timeIntervalSince(chartStart))
            let previousRuns = runs.filter { $0.date >= previousStart && $0.date < chartStart }
            previousTotal = previousRuns.reduce(0) { $0 + value(of: $1, metric) }
        }

        return Summary(
            total: total,
            averagePerBucket: buckets.isEmpty ? 0 : total / Double(buckets.count),
            best: best.flatMap { $0.value(metric) > 0 ? $0 : nil },
            previousTotal: previousTotal
        )
    }

    private static func value(of run: Run, _ metric: Metric) -> Double {
        switch metric {
        case .distance: return max(0, run.meters)
        case .time: return max(0, run.seconds)
        case .runs: return 1
        case .climb: return max(0, run.climbMeters ?? 0)
        }
    }
}
