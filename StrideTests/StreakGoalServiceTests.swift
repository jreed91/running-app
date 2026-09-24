import Foundation
import Testing
@testable import Stride

// MARK: - Streak / weekly-goal / consistency-badge tests
//
// Every case pins a UTC calendar and a fixed `now` so streak and week-boundary
// math is deterministic regardless of the machine's time zone.

@MainActor
struct StreakGoalServiceTests {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Noon on 2026-07-23. Time-of-day is mid-day so day bucketing never
    /// straddles a boundary.
    private var now: Date { day(2026, 7, 23) }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func daysBefore(_ n: Int, from date: Date) -> Date {
        calendar.date(byAdding: .day, value: -n, to: date)!
    }

    private func run(on date: Date, meters: Double = 1_000) -> RunWorkout {
        RunWorkout(date: date, distanceMeters: meters, durationSeconds: 300, workoutType: .easy)
    }

    /// Monday-anchored start of week, mirroring the service, for building
    /// week-relative fixtures without hardcoding a weekday.
    private func startOfWeek(_ date: Date) -> Date {
        var cal = calendar
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps)!
    }

    // MARK: Streak

    @Test("Consecutive days including today produce the full current streak")
    func consecutiveDaysIncludingToday() {
        let runs = [now, daysBefore(1, from: now), daysBefore(2, from: now)].map { run(on: $0) }

        let streak = StreakGoalService.streak(for: runs, now: now, calendar: calendar)

        #expect(streak.current == 3)
        #expect(streak.longest == 3)
        #expect(streak.isActiveToday)
    }

    @Test("A streak ending yesterday is still alive today before today's run")
    func streakEndingYesterdayStaysAlive() {
        let runs = [daysBefore(1, from: now), daysBefore(2, from: now), daysBefore(3, from: now)].map { run(on: $0) }

        let streak = StreakGoalService.streak(for: runs, now: now, calendar: calendar)

        #expect(streak.current == 3)
        #expect(streak.isActiveToday == false)
    }

    @Test("A gap of a full day breaks the current streak but not the longest")
    func gapBreaksCurrentStreak() {
        // Last run was two days ago — nothing today or yesterday.
        let runs = [daysBefore(2, from: now), daysBefore(3, from: now)].map { run(on: $0) }

        let streak = StreakGoalService.streak(for: runs, now: now, calendar: calendar)

        #expect(streak.current == 0)
        #expect(streak.longest == 2)
    }

    @Test("Multiple runs on the same calendar day count once")
    func multipleRunsSameDayCountOnce() {
        let runs = [run(on: now), run(on: day(2026, 7, 23, hour: 6)), run(on: daysBefore(1, from: now))]

        let streak = StreakGoalService.streak(for: runs, now: now, calendar: calendar)

        #expect(streak.current == 2)
        #expect(streak.longest == 2)
    }

    @Test("Longest streak is found across an earlier gap")
    func longestStreakAcrossGap() {
        // Current 2-day streak (today, yesterday) and an older 4-day block.
        let recent = [now, daysBefore(1, from: now)]
        let older = [daysBefore(5, from: now), daysBefore(6, from: now), daysBefore(7, from: now), daysBefore(8, from: now)]
        let runs = (recent + older).map { run(on: $0) }

        let streak = StreakGoalService.streak(for: runs, now: now, calendar: calendar)

        #expect(streak.current == 2)
        #expect(streak.longest == 4)
    }

    @Test("No runs yields an empty streak")
    func noRunsEmptyStreak() {
        let streak = StreakGoalService.streak(for: [], now: now, calendar: calendar)
        #expect(streak == .empty)
    }

    // MARK: Weekly goal

    @Test("Weekly progress sums only the current Monday–Sunday week")
    func weeklyProgressSumsCurrentWeekOnly() {
        let weekStart = startOfWeek(now)
        let runs = [
            run(on: weekStart, meters: 3_000),
            run(on: calendar.date(byAdding: .day, value: 2, to: weekStart)!, meters: 4_000),
            run(on: calendar.date(byAdding: .day, value: 6, to: weekStart)!, meters: 2_000), // Sunday, still this week
            run(on: daysBefore(1, from: weekStart), meters: 9_999),                           // previous week, excluded
        ]

        let progress = StreakGoalService.weeklyProgress(for: runs, goalMeters: 10_000, now: now, calendar: calendar)

        #expect(progress.completedMeters == 9_000)
        #expect(progress.remainingMeters == 1_000)
        #expect(progress.isMet == false)
        #expect(abs(progress.fraction - 0.9) < 0.0001)
    }

    @Test("Meeting the goal clamps the fraction and reports met")
    func weeklyGoalMetClamps() {
        let weekStart = startOfWeek(now)
        let runs = [run(on: weekStart, meters: 8_000)]

        let progress = StreakGoalService.weeklyProgress(for: runs, goalMeters: 5_000, now: now, calendar: calendar)

        #expect(progress.isMet)
        #expect(progress.fraction == 1.0)
        #expect(progress.remainingMeters == 0)
    }

    @Test("A zero goal never reports as met")
    func weeklyZeroGoalNotMet() {
        let runs = [run(on: startOfWeek(now), meters: 5_000)]
        let progress = StreakGoalService.weeklyProgress(for: runs, goalMeters: 0, now: now, calendar: calendar)

        #expect(progress.fraction == 0)
        #expect(progress.isMet == false)
    }

    // MARK: Consistency badges

    @Test("A seven-day streak earns the 7-day badge but not the 30-day badge")
    func streakBadgeEarnedAtSeven() {
        let runs = (0..<7).map { run(on: daysBefore($0, from: now)) }

        let badges = StreakGoalService.achievements(for: runs, unit: .metric, now: now, calendar: calendar)

        #expect(badge(badges, "streak-7")?.isEarned == true)
        #expect(badge(badges, "streak-30")?.isEarned == false)
        // 7 of 30 days ≈ 0.23 progress on the locked badge.
        #expect(abs((badge(badges, "streak-30")?.progress ?? 0) - 7.0 / 30.0) < 0.0001)
    }

    @Test("Lifetime distance badges are unit-aware and reflect total distance")
    func lifetimeBadgesUnitAware() {
        // One run of ~124 mi (200 km): clears the 100-unit tier in both systems.
        let runs = [run(on: now, meters: 200_000)]

        let metric = StreakGoalService.achievements(for: runs, unit: .metric, now: now, calendar: calendar)
        #expect(badge(metric, "lifetime-100 km")?.isEarned == true)
        #expect(badge(metric, "lifetime-1000 km")?.isEarned == false)

        let imperial = StreakGoalService.achievements(for: runs, unit: .imperial, now: now, calendar: calendar)
        #expect(badge(imperial, "lifetime-100 mi")?.isEarned == true)
        #expect(badge(imperial, "lifetime-500 mi")?.isEarned == false)
    }

    @Test("A big single week earns the week-volume badges up to its total")
    func singleWeekVolumeBadges() {
        // Five 11 km runs inside one Monday–Sunday week = 55 km.
        let weekStart = startOfWeek(now)
        let runs = (0..<5).map { offset in
            run(on: calendar.date(byAdding: .day, value: offset, to: weekStart)!, meters: 11_000)
        }

        let badges = StreakGoalService.achievements(for: runs, unit: .metric, now: now, calendar: calendar)

        #expect(badge(badges, "week-25 km")?.isEarned == true)
        #expect(badge(badges, "week-50 km")?.isEarned == true)
        #expect(badge(badges, "week-100 km")?.isEarned == false)
    }

    @Test("A big calendar month earns the month-volume badges up to its total")
    func singleMonthVolumeBadges() {
        // Ten 12 km runs across July = 120 km, plus 90 km in June that must not be pooled.
        let july = (1...10).map { run(on: day(2026, 7, $0), meters: 12_000) }
        let june = (1...9).map { run(on: day(2026, 6, $0 * 3), meters: 10_000) }

        let badges = StreakGoalService.achievements(for: july + june, unit: .metric, now: now, calendar: calendar)

        #expect(badge(badges, "month-100 km")?.isEarned == true)
        #expect(badge(badges, "month-200 km")?.isEarned == false)
        #expect(abs((badge(badges, "month-200 km")?.progress ?? 0) - 0.6) < 0.0001)
    }

    @Test("Month-volume badges are unit-aware")
    func monthVolumeBadgesImperial() {
        // 100 km in one month ≈ 62 mi: clears 60 mi, not 125 mi.
        let runs = (1...10).map { run(on: day(2026, 7, $0), meters: 10_000) }

        let badges = StreakGoalService.achievements(for: runs, unit: .imperial, now: now, calendar: calendar)

        #expect(badge(badges, "month-60 mi")?.isEarned == true)
        #expect(badge(badges, "month-125 mi")?.isEarned == false)
    }

    @Test("Long-run badges read the single longest run, not a sum")
    func longRunBadges() {
        // Two 15 km runs: 30 km in total, but no single run reaches a half marathon.
        let runs = [run(on: now, meters: 15_000), run(on: daysBefore(2, from: now), meters: 15_000)]

        let badges = StreakGoalService.achievements(for: runs, unit: .metric, now: now, calendar: calendar)

        #expect(badge(badges, "longest-10k")?.isEarned == true)
        #expect(badge(badges, "longest-half")?.isEarned == false)
        #expect(badge(badges, "longest-marathon")?.isEarned == false)
    }

    @Test("A half marathon measured slightly short by GPS still earns the badge")
    func longRunBadgeTolerance() {
        let shortByGPS = [run(on: now, meters: 20_950)]  // 99.3% of 21 097.5 m
        let genuinelyShort = [run(on: now, meters: 20_500)]  // 97.2%

        let earned = StreakGoalService.achievements(for: shortByGPS, unit: .metric, now: now, calendar: calendar)
        let notEarned = StreakGoalService.achievements(for: genuinelyShort, unit: .metric, now: now, calendar: calendar)

        #expect(badge(earned, "longest-half")?.isEarned == true)
        #expect(badge(notEarned, "longest-half")?.isEarned == false)
    }

    @Test("A long walk earns no long-run badge")
    func walksDoNotEarnLongRunBadges() {
        let walk = RunWorkout(date: now, distanceMeters: 25_000, durationSeconds: 18_000, workoutType: .walk)

        let badges = StreakGoalService.achievements(for: [walk], unit: .metric, now: now, calendar: calendar)

        #expect(badge(badges, "longest-half")?.isEarned == false)
        #expect(badge(badges, "month-100 km")?.progress == 0)
    }

    private func badge(_ list: [StreakGoalService.Achievement], _ id: String) -> StreakGoalService.Achievement? {
        list.first { $0.id == id }
    }
}
