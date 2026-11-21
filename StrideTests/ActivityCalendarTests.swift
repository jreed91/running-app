import Foundation
import Testing
@testable import Stride

/// Covers `ActivityCalendar` (the year grid) and `RouteThinning` (the heatmap's routes).
struct ActivityCalendarTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, hour: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: month, day: day, hour: hour))!
    }

    /// Wednesday 17 March 2027.
    private var now: Date { date(3, 17, hour: 12) }

    private func run(_ date: Date, _ meters: Double) -> ActivityCalendar.Run {
        ActivityCalendar.Run(id: UUID(), date: date, meters: meters)
    }

    @Test func weeksAreMondayFirstAndEndThisWeek() {
        let weeks = ActivityCalendar.weeks(4, runs: [], now: now, calendar: calendar)
        #expect(weeks.count == 4)
        #expect(weeks.last?.start == date(3, 15, hour: 0))
        #expect(weeks.first?.start == date(2, 22, hour: 0))
        #expect(weeks.allSatisfy { $0.days.count == 7 })
    }

    @Test func futureDaysAreMarked() {
        let weeks = ActivityCalendar.weeks(1, runs: [], now: now, calendar: calendar)
        #expect(weeks[0].days.map(\.isFuture) == [false, false, false, true, true, true, true])
    }

    @Test func sameDayRunsAdd() {
        let weeks = ActivityCalendar.weeks(1, runs: [run(date(3, 16), 5_000), run(date(3, 16, hour: 18), 3_000)],
                                           now: now, calendar: calendar)
        let tuesday = weeks[0].days[1]
        #expect(tuesday.meters == 8_000)
        #expect(tuesday.runIDs.count == 2)
    }

    @Test func levelsFollowTheRunnersOwnQuartiles() {
        let runs = [
            run(date(3, 1), 3_000), run(date(3, 2), 5_000), run(date(3, 3), 8_000),
            run(date(3, 4), 10_000), run(date(3, 6), 21_000),
        ]
        let weeks = ActivityCalendar.weeks(3, runs: runs, now: now, calendar: calendar)
        let levels = weeks[0].days.map(\.level)
        // Mon 3k, Tue 5k, Wed 8k, Thu 10k, Fri rest, Sat 21k, Sun rest.
        #expect(levels == [1, 1, 2, 3, 0, 4, 0])
        #expect(levels[4] == 0)
        #expect(levels[5] == 4)
    }

    @Test func runsBeforeTheGridAreIgnored() {
        let weeks = ActivityCalendar.weeks(1, runs: [run(date(1, 5), 10_000)], now: now, calendar: calendar)
        #expect(weeks[0].days.allSatisfy { $0.runIDs.isEmpty })
    }

    @Test func streakSkipsAnUnfinishedEmptyWeek() {
        let runs = [run(date(3, 1), 5_000), run(date(3, 9), 5_000)]
        let weeks = ActivityCalendar.weeks(4, runs: runs, now: now, calendar: calendar)
        #expect(ActivityCalendar.currentWeekStreak(weeks) == 2)
    }

    @Test func streakBreaksOnAnEmptyPastWeek() {
        let runs = [run(date(2, 22), 5_000), run(date(3, 15), 5_000)]
        let weeks = ActivityCalendar.weeks(4, runs: runs, now: now, calendar: calendar)
        #expect(ActivityCalendar.currentWeekStreak(weeks) == 1)
    }

    @Test func thinningKeepsBothEnds() {
        let thinned = RouteThinning.thinned(Array(0..<1_000), limit: 10)
        #expect(thinned.count == 10)
        #expect(thinned.first == 0)
        #expect(thinned.last == 999)
    }

    @Test func shortRoutesAreUntouched() {
        #expect(RouteThinning.thinned([1, 2, 3], limit: 10) == [1, 2, 3])
    }
}
