import Foundation

// MARK: - StreakGoalService

/// Pure, stateless helpers for the streaks / weekly-goal / consistency-badge
/// ("Achievements") surface. Like `ProgressStatsService`, all logic lives here —
/// not in view bodies — so it can be unit tested (see AGENTS.md). Every entry
/// point takes an injectable `now` and `calendar` so tests can pin a reference
/// date and time zone rather than depending on the wall clock.
struct StreakGoalService: Sendable {

    // MARK: Run streak

    /// A run streak: consecutive calendar days on which at least one run was
    /// logged. Multiple runs on the same day count once; a rest day breaks it.
    struct StreakSummary: Equatable, Sendable {
        /// Length of the streak ending today (or yesterday — see below), in days.
        let current: Int
        /// Longest streak ever recorded across all runs.
        let longest: Int
        /// Whether a run has already been logged today.
        let isActiveToday: Bool

        static let empty = StreakSummary(current: 0, longest: 0, isActiveToday: false)
    }

    /// Computes the current and longest consecutive-calendar-day run streaks.
    ///
    /// The current streak stays "alive" through today even before today's run:
    /// it is anchored at today when a run exists today, otherwise at yesterday
    /// when one exists there, and is 0 only once a full calendar day has passed
    /// with no run. This avoids a streak reading as broken every morning.
    static func streak(
        for runs: [RunWorkout],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> StreakSummary {
        // A streak is a *running* streak. Filtered here rather than at the caller
        // because that is the claim the number makes on screen (N38).
        let days = Set(runs.runsOnly.map { calendar.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return .empty }

        // Longest run of consecutive days across all recorded days.
        let sorted = days.sorted()
        var longest = 1
        var run = 1
        for index in 1..<sorted.count {
            let expected = calendar.date(byAdding: .day, value: 1, to: sorted[index - 1])
            if let expected, calendar.isDate(expected, inSameDayAs: sorted[index]) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }

        // Current streak: anchor at today if it has a run, else yesterday.
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let isActiveToday = days.contains(today)

        var anchor: Date?
        if days.contains(today) {
            anchor = today
        } else if let yesterday, days.contains(yesterday) {
            anchor = yesterday
        }

        var current = 0
        var cursor = anchor
        while let day = cursor, days.contains(day) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }

        return StreakSummary(current: current, longest: max(longest, current), isActiveToday: isActiveToday)
    }

    // MARK: Weekly goal

    /// Progress toward the user's weekly distance goal for the week containing
    /// `now` (weeks start Monday, matching `Date.startOfWeek`).
    struct WeeklyGoalProgress: Equatable, Sendable {
        /// The goal distance in metres. Zero means "no goal set".
        let goalMeters: Double
        /// Distance run so far this week, in metres.
        let completedMeters: Double

        /// Fraction of the goal completed, clamped to `0...1`.
        var fraction: Double {
            guard goalMeters > 0 else { return 0 }
            return min(completedMeters / goalMeters, 1)
        }

        /// Whether the goal has been met or exceeded this week.
        var isMet: Bool { goalMeters > 0 && completedMeters >= goalMeters }

        /// Distance still to go this week, in metres (never negative).
        var remainingMeters: Double { max(goalMeters - completedMeters, 0) }
    }

    /// Sums the current week's run distance and compares it to `goalMeters`. The weekly
    /// goal is a running goal, so imported walks are not counted toward it (N38).
    static func weeklyProgress(
        for runs: [RunWorkout],
        goalMeters: Double,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WeeklyGoalProgress {
        let weekStart = startOfWeek(for: now, calendar: calendar)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let completed = runs.runsOnly
            .filter { $0.date >= weekStart && $0.date < weekEnd }
            .reduce(0) { $0 + $1.distanceMeters }
        return WeeklyGoalProgress(goalMeters: goalMeters, completedMeters: completed)
    }

    // MARK: Consistency badges

    enum AchievementCategory: String, Sendable, CaseIterable {
        case streak
        case lifetimeDistance
        case singleWeekVolume

        var systemImage: String {
            switch self {
            case .streak: return "flame.fill"
            case .lifetimeDistance: return "figure.run"
            case .singleWeekVolume: return "calendar"
            }
        }

        var sectionTitle: String {
            switch self {
            case .streak: return "Streaks"
            case .lifetimeDistance: return "Lifetime Distance"
            case .singleWeekVolume: return "Big Weeks"
            }
        }
    }

    /// A single milestone badge, earned or still locked, with fractional
    /// progress so the UI can show how close an unearned badge is.
    struct Achievement: Identifiable, Equatable, Sendable {
        let id: String
        let category: AchievementCategory
        let title: String
        let detail: String
        let isEarned: Bool
        /// Progress toward earning, clamped to `0...1` (1 when earned).
        let progress: Double
    }

    /// Builds the full badge list (earned and locked) for the given runs, with
    /// distance thresholds chosen to match the user's unit preference.
    static func achievements(
        for runs: [RunWorkout],
        unit: UnitPreference,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Achievement] {
        // Every badge below counts running: kilometres run, weeks run, days run in a
        // row. Filtered once here so no milestone has to remember (N38).
        let runs = runs.runsOnly
        let longestStreak = streak(for: runs, now: now, calendar: calendar).longest
        let lifetimeMeters = runs.reduce(0) { $0 + $1.distanceMeters }
        let bestWeekMeters = bestWeeklyVolumeMeters(for: runs, calendar: calendar)

        var result: [Achievement] = []

        for milestone in streakMilestones {
            result.append(Achievement(
                id: "streak-\(milestone)",
                category: .streak,
                title: "\(milestone)-Day Streak",
                detail: "Run \(milestone) days in a row",
                isEarned: longestStreak >= milestone,
                progress: fraction(Double(longestStreak), of: Double(milestone))
            ))
        }

        for tier in lifetimeThresholds(unit: unit) {
            result.append(Achievement(
                id: "lifetime-\(tier.label)",
                category: .lifetimeDistance,
                title: tier.label,
                detail: "Run \(tier.label) total",
                isEarned: lifetimeMeters >= tier.meters,
                progress: fraction(lifetimeMeters, of: tier.meters)
            ))
        }

        for tier in weekVolumeThresholds(unit: unit) {
            result.append(Achievement(
                id: "week-\(tier.label)",
                category: .singleWeekVolume,
                title: tier.label,
                detail: "Run \(tier.label) in one week",
                isEarned: bestWeekMeters >= tier.meters,
                progress: fraction(bestWeekMeters, of: tier.meters)
            ))
        }

        return result
    }

    // MARK: - Thresholds

    /// Streak length milestones, in days.
    static let streakMilestones = [7, 30, 100]

    private struct DistanceTier { let label: String; let meters: Double }

    private static let metersPerMile = 1_609.344

    private static func lifetimeThresholds(unit: UnitPreference) -> [DistanceTier] {
        switch unit {
        case .metric:
            return [
                DistanceTier(label: "100 km", meters: 100_000),
                DistanceTier(label: "500 km", meters: 500_000),
                DistanceTier(label: "1000 km", meters: 1_000_000),
            ]
        case .imperial:
            return [
                DistanceTier(label: "100 mi", meters: 100 * metersPerMile),
                DistanceTier(label: "500 mi", meters: 500 * metersPerMile),
                DistanceTier(label: "1000 mi", meters: 1_000 * metersPerMile),
            ]
        }
    }

    private static func weekVolumeThresholds(unit: UnitPreference) -> [DistanceTier] {
        switch unit {
        case .metric:
            return [
                DistanceTier(label: "25 km", meters: 25_000),
                DistanceTier(label: "50 km", meters: 50_000),
                DistanceTier(label: "100 km", meters: 100_000),
            ]
        case .imperial:
            return [
                DistanceTier(label: "15 mi", meters: 15 * metersPerMile),
                DistanceTier(label: "30 mi", meters: 30 * metersPerMile),
                DistanceTier(label: "60 mi", meters: 60 * metersPerMile),
            ]
        }
    }

    // MARK: - Helpers

    /// Highest single-week (Monday-anchored) total run distance across all runs.
    private static func bestWeeklyVolumeMeters(for runs: [RunWorkout], calendar: Calendar) -> Double {
        var totalsByWeek: [Date: Double] = [:]
        for run in runs {
            let weekStart = startOfWeek(for: run.date, calendar: calendar)
            totalsByWeek[weekStart, default: 0] += run.distanceMeters
        }
        return totalsByWeek.values.max() ?? 0
    }

    /// Monday-anchored start of the week containing `date`, computed with the
    /// injected calendar so tests stay deterministic. Mirrors `Date.startOfWeek`.
    ///
    /// Not private: `WidgetSnapshotBuilder` counts the same week's runs for the weekly
    /// widget, and a second copy of this — the third, counting `Date.startOfWeek` — is
    /// how the widget and the Achievements screen end up disagreeing by one run every
    /// Sunday. `Date.startOfWeek` remains the form to use where a calendar need not be
    /// injected.
    static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: components) ?? cal.startOfDay(for: date)
    }

    private static func fraction(_ value: Double, of target: Double) -> Double {
        guard target > 0 else { return 0 }
        return min(max(value / target, 0), 1)
    }
}
