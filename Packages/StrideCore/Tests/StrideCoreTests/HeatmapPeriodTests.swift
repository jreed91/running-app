import Foundation
import Testing
@testable import StrideCore

/// Covers `HeatmapPeriod`: what each choice includes and what the picker offers.
struct HeatmapPeriodTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func opensOnTheProgressPeriod() {
        #expect(HeatmapPeriod(progressDays: nil) == .all)
        #expect(HeatmapPeriod(progressDays: 90) == .lastDays(90))
    }

    @Test func allTimeTakesEverything() {
        let now = date(2026, 11, 23)
        #expect(HeatmapPeriod.all.contains(date(2001, 1, 1), now: now, calendar: calendar))
        #expect(HeatmapPeriod.all.interval(now: now, calendar: calendar) == nil)
    }

    @Test func aRollingWindowEndsNow() {
        let now = date(2026, 11, 23)
        let period = HeatmapPeriod.lastDays(30)
        #expect(period.contains(now, now: now, calendar: calendar))
        #expect(period.contains(date(2026, 10, 25), now: now, calendar: calendar))
        #expect(!period.contains(date(2026, 10, 23), now: now, calendar: calendar))
    }

    @Test func aYearIsMidnightToMidnightInLocalTime() {
        let now = date(2026, 11, 23)
        let period = HeatmapPeriod.year(2025)
        #expect(period.contains(date(2025, 1, 1, hour: 0), now: now, calendar: calendar))
        #expect(period.contains(date(2025, 12, 31, hour: 23), now: now, calendar: calendar))
        #expect(!period.contains(date(2026, 1, 1, hour: 0), now: now, calendar: calendar))
        #expect(!period.contains(date(2024, 12, 31, hour: 23), now: now, calendar: calendar))
    }

    @Test func offersEveryYearWithARunNewestFirst() {
        let runs = [date(2023, 5, 1), date(2025, 2, 1), date(2025, 8, 1), date(2026, 3, 1)]
        let choices = HeatmapPeriod.choices(runDates: runs, calendar: calendar)
        #expect(choices == [.all, .lastDays(30), .lastDays(90), .lastDays(180), .lastDays(365), .year(2026), .year(2025), .year(2023)])
    }

    @Test func noRunsOffersOnlyTheWindows() {
        #expect(HeatmapPeriod.choices(runDates: [], calendar: calendar).count == 1 + HeatmapPeriod.windows.count)
    }

    @Test func everyProgressPeriodIsOnOffer() {
        for period in ProgressFilter.Period.allCases {
            let choice = HeatmapPeriod(progressDays: period.days)
            #expect(HeatmapPeriod.choices(runDates: [], calendar: calendar).contains(choice))
        }
    }
}
