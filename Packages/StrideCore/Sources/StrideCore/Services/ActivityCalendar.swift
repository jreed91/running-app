import Foundation

// MARK: - ActivityCalendar

/// A year of running as a grid: a column per week, a row per weekday, each day shaded by
/// how far was run. The shape of a training year, read at a glance.
///
/// Pure and `Sendable`; the view turns runs into ``Run``s.
enum ActivityCalendar {

    struct Run: Equatable, Sendable {
        let id: UUID
        let date: Date
        let meters: Double
    }

    struct Day: Equatable, Sendable, Identifiable {
        let date: Date
        let meters: Double
        let runIDs: [UUID]
        /// 0 for a rest day, then 1...4 by the runner's own quartiles of running days.
        let level: Int
        /// Days after `now` are drawn empty, not as rest.
        let isFuture: Bool

        var id: Date { date }
    }

    struct Week: Equatable, Sendable, Identifiable {
        let start: Date
        /// Always seven, Monday first.
        let days: [Day]

        var id: Date { start }
    }

    /// The last `weeks` weeks to `now`'s, Monday first, oldest week first.
    static func weeks(
        _ weeks: Int,
        runs: [Run],
        now: Date,
        calendar baseCalendar: Calendar
    ) -> [Week] {
        var calendar = baseCalendar
        calendar.firstWeekday = 2
        guard weeks > 0,
              let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let firstWeek = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)
        else { return [] }
        let today = calendar.startOfDay(for: now)

        var meters: [Date: Double] = [:]
        var ids: [Date: [UUID]] = [:]
        for run in runs.sorted(by: { $0.date < $1.date }) where run.date >= firstWeek {
            let day = calendar.startOfDay(for: run.date)
            meters[day, default: 0] += max(0, run.meters)
            ids[day, default: []].append(run.id)
        }
        let thresholds = quartiles(of: meters.values.filter { $0 > 0 })

        return (0..<weeks).compactMap { offset -> Week? in
            guard let start = calendar.date(byAdding: .weekOfYear, value: offset, to: firstWeek) else { return nil }
            let days = (0..<7).compactMap { dayOffset -> Day? in
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: start) else { return nil }
                let distance = meters[date] ?? 0
                return Day(
                    date: date,
                    meters: distance,
                    runIDs: ids[date] ?? [],
                    level: level(for: distance, thresholds: thresholds),
                    isFuture: date > today
                )
            }
            return Week(start: start, days: days)
        }
    }

    /// The 25th, 50th and 75th percentiles of the running days' distances.
    static func quartiles(of values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let sorted = values.sorted()
        return [0.25, 0.5, 0.75].map { fraction in
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
        }
    }

    static func level(for meters: Double, thresholds: [Double]) -> Int {
        guard meters > 0 else { return 0 }
        guard thresholds.count == 3 else { return 2 }
        if meters <= thresholds[0] { return 1 }
        if meters <= thresholds[1] { return 2 }
        if meters <= thresholds[2] { return 3 }
        return 4
    }

    /// Longest run of consecutive weeks, ending at the latest, with at least one run.
    static func currentWeekStreak(_ weeks: [Week]) -> Int {
        var streak = 0
        for week in weeks.reversed() {
            let ran = week.days.contains { !$0.runIDs.isEmpty }
            // This week doesn't break a streak just because it isn't over.
            if !ran, week.id == weeks.last?.id { continue }
            guard ran else { break }
            streak += 1
        }
        return streak
    }
}

// MARK: - RouteThinning

/// Fewer points for drawing many routes at once on one map: every route in a year on the
/// personal heatmap would otherwise be hundreds of thousands of coordinates.
enum RouteThinning {
    /// At most `limit` points, evenly picked, always keeping the first and last.
    static func thinned<T>(_ points: [T], limit: Int) -> [T] {
        guard limit >= 2, points.count > limit else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[Int((Double($0) * step).rounded())] }
    }
}
