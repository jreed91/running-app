import Foundation

// MARK: - TrendExplorer

/// The arithmetic behind the trend explorer: one value per run (an easy pace, an easy
/// run's heart rate, a VDOT estimate, a cadence), the typical value each week, and
/// whether it is moving the right way.
///
/// Pure and `Sendable`, like ``VolumeExplorer``. The view decides which runs carry a value
/// for each metric and hands over ``Point``s, so the rules here are tested without
/// SwiftData.
enum TrendExplorer {

    /// What the dots measure.
    enum Metric: String, CaseIterable, Sendable {
        /// Easy and long runs only, so the effort is held steady.
        case easyPace
        /// Heart rate on those same runs: falling at the same effort is fitness.
        case easyHeartRate
        /// Estimated from quality sessions and races.
        case vdot
        /// Steps per minute, every run.
        case cadence

        /// Which way is better, or `nil` when neither is: a cadence is a style, not a score.
        var lowerIsBetter: Bool? {
            switch self {
            case .easyPace, .easyHeartRate: return true
            case .vdot: return false
            case .cadence: return nil
            }
        }
    }

    /// One run's value.
    struct Point: Equatable, Sendable, Identifiable {
        let id: UUID
        let date: Date
        let value: Double
    }

    /// The typical value one week.
    struct Week: Equatable, Sendable {
        let weekStart: Date
        /// The mean time of the week's runs, so the line runs through its own dots and
        /// never ahead of today.
        let plotDate: Date
        /// Median, so one hilly run or one hot day doesn't drag the line.
        let value: Double
    }

    struct Trend: Equatable, Sendable {
        /// Oldest first.
        let points: [Point]
        /// One per week that had a point, oldest first.
        let weeks: [Week]
        /// Median of the later half of the points minus the earlier half, in the metric's
        /// own units. `nil` below ``minimumPointsForChange`` points or
        /// ``minimumWeeksForChange`` weeks, where a change is noise.
        let change: Double?
        /// The best single run, or `nil` when the metric has no better direction.
        let best: Point?

        var latestWeek: Week? { weeks.last }

        /// Whether ``change`` is an improvement, or `nil` when it has no direction, is
        /// missing, or rounds to nothing.
        func isImprovement(for metric: Metric, threshold: Double = 0) -> Bool? {
            guard let change, let lowerIsBetter = metric.lowerIsBetter, abs(change) > threshold else {
                return nil
            }
            return lowerIsBetter ? change < 0 : change > 0
        }
    }

    static let minimumPointsForChange = 4
    static let minimumWeeksForChange = 3

    /// The trend over the points on or after `start`. Non-finite and non-positive values
    /// are dropped: they are a missing reading, never a real pace or heart rate.
    static func trend(
        for points: [Point],
        metric: Metric,
        from start: Date,
        calendar: Calendar
    ) -> Trend {
        let points = points
            .filter { $0.date >= start && $0.value > 0 && $0.value.isFinite }
            .sorted { $0.date < $1.date }

        let weeks = Dictionary(grouping: points) {
            VolumeExplorer.periodStart(of: $0.date, grouping: .week, calendar: calendar)
        }
        .compactMap { weekStart, weekPoints -> Week? in
            guard let value = median(weekPoints.map(\.value)) else { return nil }
            let meanTime = weekPoints.reduce(0) { $0 + $1.date.timeIntervalSinceReferenceDate }
                / Double(weekPoints.count)
            return Week(
                weekStart: weekStart,
                plotDate: Date(timeIntervalSinceReferenceDate: meanTime),
                value: value
            )
        }
        .sorted { $0.weekStart < $1.weekStart }

        var change: Double?
        if points.count >= minimumPointsForChange, weeks.count >= minimumWeeksForChange {
            let half = points.count / 2
            if let before = median(points.prefix(half).map(\.value)),
               let after = median(points.suffix(half).map(\.value)) {
                change = after - before
            }
        }

        let best: Point?
        switch metric.lowerIsBetter {
        case .some(true): best = points.min { $0.value < $1.value }
        case .some(false): best = points.max { $0.value < $1.value }
        case .none: best = nil
        }

        return Trend(points: points, weeks: weeks, change: change, best: best)
    }

    /// The point nearest a chart selection.
    static func point(nearest date: Date, in points: [Point]) -> Point? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// Middle value, or the mean of the middle two; `nil` for an empty sample.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
