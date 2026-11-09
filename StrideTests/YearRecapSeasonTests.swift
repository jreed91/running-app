import Foundation
import Testing
@testable import Stride

/// Covers `YearRecapSeason`: which year's recap is offered, and when Home shows it.
struct YearRecapSeasonTests {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("January offers last year's recap; the rest of the year offers this year's")
    func recapYear() {
        #expect(YearRecapSeason.recapYear(now: day(2027, 1, 31, hour: 23), calendar: calendar) == 2026)
        #expect(YearRecapSeason.recapYear(now: day(2027, 2, 1, hour: 0), calendar: calendar) == 2027)
        #expect(YearRecapSeason.recapYear(now: day(2026, 11, 9), calendar: calendar) == 2026)
        #expect(YearRecapSeason.recapYear(now: day(2026, 12, 31, hour: 23), calendar: calendar) == 2026)
    }

    @Test("Home shows the recap in December and January only")
    func homeSeason() {
        #expect(!YearRecapSeason.isHomeSeason(now: day(2026, 11, 30, hour: 23), calendar: calendar))
        #expect(YearRecapSeason.isHomeSeason(now: day(2026, 12, 1, hour: 0), calendar: calendar))
        #expect(YearRecapSeason.isHomeSeason(now: day(2027, 1, 31, hour: 23), calendar: calendar))
        #expect(!YearRecapSeason.isHomeSeason(now: day(2027, 2, 1, hour: 0), calendar: calendar))
    }

    @Test("A year's interval runs from 1 January to the next 1 January")
    func interval() {
        let interval = YearRecapSeason.interval(of: 2026, calendar: calendar)
        #expect(interval?.start == day(2026, 1, 1, hour: 0))
        #expect(interval?.end == day(2027, 1, 1, hour: 0))
    }
}
