import Foundation

// MARK: - HeatmapPeriod

/// Which runs the full-screen heatmap shows: all time, a rolling window, or one calendar
/// year. Years are what runners compare ("where did I run in 2024?"), so each year with
/// a run gets its own choice.
///
/// Pure and `Sendable`, like ``ProgressFilter``.
enum HeatmapPeriod: Hashable, Sendable, Identifiable {
    case all
    case lastDays(Int)
    case year(Int)

    var id: String {
        switch self {
        case .all: return "all"
        case .lastDays(let days): return "last-\(days)"
        case .year(let year): return "year-\(year)"
        }
    }

    /// The rolling windows offered, shortest first.
    static let windows = [30, 90, 180, 365]

    /// The period that matches the Progress page's filter, so the full-screen map opens
    /// on what the card was showing.
    init(progressDays: Int?) {
        guard let days = progressDays else {
            self = .all
            return
        }
        self = .lastDays(days)
    }

    /// The span of dates included, or `nil` for all time. Rolling windows end now; a year
    /// runs from its first midnight to the next year's.
    func interval(now: Date, calendar: Calendar) -> DateInterval? {
        switch self {
        case .all:
            return nil
        case .lastDays(let days):
            return DateInterval(start: now.addingTimeInterval(-Double(days) * 86_400), end: now)
        case .year(let year):
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    /// Whether a run on `date` is in the period. Start inclusive, end exclusive, except a
    /// rolling window, which takes a run that finished this very second.
    func contains(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let interval = interval(now: now, calendar: calendar) else { return true }
        if case .lastDays = self { return date >= interval.start && date <= interval.end }
        return date >= interval.start && date < interval.end
    }

    /// Everything the picker offers: all time, the rolling windows, then every year with
    /// a run, newest first.
    static func choices(runDates: [Date], calendar: Calendar) -> [HeatmapPeriod] {
        let years = Set(runDates.map { calendar.component(.year, from: $0) })
        return [.all] + windows.map { .lastDays($0) } + years.sorted(by: >).map { .year($0) }
    }
}
