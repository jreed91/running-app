import Foundation
import Testing
@testable import Stride

/// Covers `TrendSeries`: trend charts reduced to a point per week or month, and a date
/// axis that stays readable over years.
struct TrendSeriesTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 7))!
    }

    @Test func groupsByMonthWithEachStatistic() {
        let points = [
            TrendSeries.Point(date: date(2025, 3, 2), value: 150),
            TrendSeries.Point(date: date(2025, 3, 20), value: 160),
            TrendSeries.Point(date: date(2025, 3, 28), value: 200),
            TrendSeries.Point(date: date(2025, 5, 1), value: 140),
        ]
        let mean = TrendSeries.buckets(points, grouping: .month, statistic: .mean, calendar: calendar)
        #expect(mean.map(\.value) == [170, 140])
        #expect(mean.map(\.count) == [3, 1])
        #expect(mean.first?.start == calendar.date(from: DateComponents(year: 2025, month: 3, day: 1)))
        #expect(TrendSeries.buckets(points, grouping: .month, statistic: .median, calendar: calendar).first?.value == 160)
        #expect(TrendSeries.buckets(points, grouping: .month, statistic: .sum, calendar: calendar).first?.value == 510)
        #expect(TrendSeries.buckets(points, grouping: .month, statistic: .max, calendar: calendar).first?.value == 200)
    }

    @Test func aThousandRunsOverFiveYearsAreSixtyPoints() {
        let start = date(2021, 1, 1)
        let points = (0..<1_000).map {
            TrendSeries.Point(date: start.addingTimeInterval(Double($0) * 1.8 * 86_400), value: 150)
        }
        let monthly = TrendSeries.buckets(points, grouping: .month, statistic: .mean, calendar: calendar)
        #expect(monthly.count <= 61)
        #expect(monthly == monthly.sorted { $0.start < $1.start })
    }

    @Test func plotDateSitsAmongTheRuns() {
        let points = [
            TrendSeries.Point(date: date(2025, 3, 10), value: 1),
            TrendSeries.Point(date: date(2025, 3, 12), value: 1),
        ]
        let bucket = TrendSeries.buckets(points, grouping: .week, statistic: .mean, calendar: calendar).first
        #expect(bucket?.plotDate == date(2025, 3, 11))
    }

    @Test func nearestPicksTheClosestBucket() {
        let points = [
            TrendSeries.Point(date: date(2025, 1, 15), value: 1),
            TrendSeries.Point(date: date(2025, 4, 15), value: 2),
        ]
        let buckets = TrendSeries.buckets(points, grouping: .month, statistic: .mean, calendar: calendar)
        #expect(TrendSeries.nearest(to: date(2025, 3, 20), in: buckets)?.value == 2)
    }

    @Test func implausibleValuesAreOutsideTheRanges() {
        // 114:00 per mile, the outlier from the phone screenshot.
        #expect(!TrendSeries.plausiblePaceSecondsPerKm.contains(114 * 60 / 1.609344))
        #expect(TrendSeries.plausiblePaceSecondsPerKm.contains(330))
        #expect(!TrendSeries.plausibleHeartRate.contains(62))
        #expect(TrendSeries.plausibleHeartRate.contains(150))
    }

    @Test func dateAxisKeepsToAboutSixLabels() {
        let now = date(2026, 11, 21)
        func axis(monthsBack: Int) -> TrendSeries.DateAxis {
            TrendSeries.dateAxis(from: calendar.date(byAdding: .month, value: -monthsBack, to: now)!, to: now, calendar: calendar)
        }
        #expect(axis(monthsBack: 3) == .init(unit: .month, count: 1, label: .month))
        #expect(axis(monthsBack: 12) == .init(unit: .month, count: 2, label: .month))
        #expect(axis(monthsBack: 20) == .init(unit: .month, count: 6, label: .monthYear))
        #expect(axis(monthsBack: 60) == .init(unit: .year, count: 1, label: .year))
        #expect(axis(monthsBack: 150) == .init(unit: .year, count: 3, label: .year))
    }
}
