import Foundation
import Testing
@testable import Stride

/// Covers `TrendExplorer`, the per-run trend behind the trend explorer.
struct TrendExplorerTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, hour: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: month, day: day, hour: hour))!
    }

    private func point(_ date: Date, _ value: Double) -> TrendExplorer.Point {
        TrendExplorer.Point(id: UUID(), date: date, value: value)
    }

    /// Four weeks of Monday and Thursday runs, getting faster.
    private var improvingPaces: [TrendExplorer.Point] {
        [
            point(date(3, 1), 360), point(date(3, 4), 358),
            point(date(3, 8), 354), point(date(3, 11), 352),
            point(date(3, 15), 348), point(date(3, 18), 346),
            point(date(3, 22), 342), point(date(3, 25), 340),
        ]
    }

    @Test func pointsBeforeTheWindowAreDropped() {
        let trend = TrendExplorer.trend(
            for: improvingPaces, metric: .easyPace, from: date(3, 15), calendar: calendar
        )
        #expect(trend.points.count == 4)
        #expect(trend.weeks.count == 2)
    }

    @Test func missingReadingsAreDropped() {
        let points = [point(date(3, 1), 0), point(date(3, 2), .nan), point(date(3, 3), 150)]
        let trend = TrendExplorer.trend(
            for: points, metric: .easyHeartRate, from: date(1, 1), calendar: calendar
        )
        #expect(trend.points.map(\.value) == [150])
    }

    @Test func weeksTakeTheMedian() {
        let points = [point(date(3, 1), 300), point(date(3, 2), 310), point(date(3, 3), 500)]
        let trend = TrendExplorer.trend(
            for: points, metric: .easyPace, from: date(1, 1), calendar: calendar
        )
        #expect(trend.weeks.count == 1)
        #expect(trend.weeks[0].value == 310)
        #expect(trend.weeks[0].weekStart == date(3, 1, hour: 0))
    }

    @Test func changeComparesTheLaterHalfWithTheEarlier() {
        let trend = TrendExplorer.trend(
            for: improvingPaces, metric: .easyPace, from: date(1, 1), calendar: calendar
        )
        // Earlier half median (358+354)/2 = 356; later half (346+342)/2 = 344.
        #expect(trend.change == -12)
        #expect(trend.isImprovement(for: .easyPace) == true)
    }

    @Test func higherVDOTIsTheImprovement() {
        let points = improvingPaces.map { TrendExplorer.Point(id: $0.id, date: $0.date, value: 400 - $0.value) }
        let trend = TrendExplorer.trend(for: points, metric: .vdot, from: date(1, 1), calendar: calendar)
        #expect((trend.change ?? 0) > 0)
        #expect(trend.isImprovement(for: .vdot) == true)
        #expect(trend.best?.value == 60)
    }

    @Test func noChangeFromTooFewWeeks() {
        let points = [
            point(date(3, 1), 360), point(date(3, 2), 358),
            point(date(3, 3), 354), point(date(3, 8), 352),
        ]
        let trend = TrendExplorer.trend(for: points, metric: .easyPace, from: date(1, 1), calendar: calendar)
        #expect(trend.change == nil)
        #expect(trend.isImprovement(for: .easyPace) == nil)
    }

    @Test func cadenceHasNoBestAndNoDirection() {
        let trend = TrendExplorer.trend(
            for: improvingPaces, metric: .cadence, from: date(1, 1), calendar: calendar
        )
        #expect(trend.best == nil)
        #expect(trend.change != nil)
        #expect(trend.isImprovement(for: .cadence) == nil)
    }

    @Test func bestPaceIsTheFastest() {
        let trend = TrendExplorer.trend(
            for: improvingPaces, metric: .easyPace, from: date(1, 1), calendar: calendar
        )
        #expect(trend.best?.value == 340)
    }

    @Test func smallChangesBelowTheThresholdHaveNoDirection() {
        let trend = TrendExplorer.trend(
            for: improvingPaces, metric: .easyPace, from: date(1, 1), calendar: calendar
        )
        #expect(trend.isImprovement(for: .easyPace, threshold: 20) == nil)
    }

    @Test func nearestPointPicksTheClosestRun() {
        let picked = TrendExplorer.point(nearest: date(3, 8, hour: 20), in: improvingPaces)
        #expect(picked?.value == 354)
    }
}
