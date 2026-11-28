import Foundation
import Testing
@testable import StrideCore

/// Covers `VolumeExplorer`, the bucketing and headline behind the volume explorer.
struct VolumeExplorerTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Wednesday 17 March 2027, 09:00 UTC.
    private var now: Date { date(2027, 3, 17, hour: 9) }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func run(
        _ date: Date,
        meters: Double = 10_000,
        seconds: Double = 3_000,
        climb: Double? = nil
    ) -> VolumeExplorer.Run {
        VolumeExplorer.Run(id: UUID(), date: date, meters: meters, seconds: seconds, climbMeters: climb)
    }

    // MARK: Periods

    @Test func weeksStartOnMonday() {
        let start = VolumeExplorer.periodStart(of: now, grouping: .week, calendar: calendar)
        #expect(start == date(2027, 3, 15, hour: 0))
    }

    @Test func monthsStartOnTheFirst() {
        let start = VolumeExplorer.periodStart(of: now, grouping: .month, calendar: calendar)
        #expect(start == date(2027, 3, 1, hour: 0))
    }

    @Test func windowsCountTheSameDaysAsProgress() {
        // 3M is 90 days, as Progress's range chips count it, not three calendar months.
        let start = VolumeExplorer.windowStart(.threeMonths, now: now, earliestRun: nil, calendar: calendar)
        #expect(start == now.addingTimeInterval(-90 * 86_400))
        #expect(start == date(2026, 12, 17, hour: 9))
    }

    @Test func allTimeStartsAtTheFirstRun() {
        let first = date(2024, 6, 2)
        let start = VolumeExplorer.windowStart(.all, now: now, earliestRun: first, calendar: calendar)
        #expect(start == first)
    }

    @Test func allTimeWithNoRunsIsJustNow() {
        let start = VolumeExplorer.windowStart(.all, now: now, earliestRun: nil, calendar: calendar)
        #expect(start == now)
    }

    // MARK: Buckets

    @Test func emptyWeeksAreKept() {
        let runs = [run(date(2027, 3, 2)), run(date(2027, 3, 16))]
        let buckets = VolumeExplorer.buckets(
            for: runs, grouping: .week, from: date(2027, 3, 1), through: now, calendar: calendar
        )
        #expect(buckets.map(\.start) == [
            date(2027, 3, 1, hour: 0), date(2027, 3, 8, hour: 0), date(2027, 3, 15, hour: 0),
        ])
        #expect(buckets.map(\.runCount) == [1, 0, 1])
    }

    @Test func bucketsSumEveryMetric() {
        let runs = [
            run(date(2027, 3, 15), meters: 5_000, seconds: 1_500, climb: 40),
            run(date(2027, 3, 16), meters: 8_000, seconds: 2_400, climb: nil),
        ]
        let buckets = VolumeExplorer.buckets(
            for: runs, grouping: .week, from: date(2027, 3, 15), through: now, calendar: calendar
        )
        #expect(buckets.count == 1)
        let week = buckets[0]
        #expect(week.value(.distance) == 13_000)
        #expect(week.value(.time) == 3_900)
        #expect(week.value(.runs) == 2)
        #expect(week.value(.climb) == 40)
    }

    @Test func runsAreListedOldestFirst() {
        let later = run(date(2027, 3, 16))
        let earlier = run(date(2027, 3, 15))
        let buckets = VolumeExplorer.buckets(
            for: [later, earlier], grouping: .week, from: date(2027, 3, 15), through: now, calendar: calendar
        )
        #expect(buckets[0].runIDs == [earlier.id, later.id])
    }

    @Test func runsOutsideTheWindowAreIgnored() {
        let runs = [run(date(2027, 2, 1)), run(date(2027, 3, 16))]
        let buckets = VolumeExplorer.buckets(
            for: runs, grouping: .week, from: date(2027, 3, 15), through: now, calendar: calendar
        )
        #expect(buckets.reduce(0) { $0 + $1.runCount } == 1)
    }

    @Test func monthBucketsSpanTheWindow() {
        let buckets = VolumeExplorer.buckets(
            for: [], grouping: .month, from: date(2026, 12, 17), through: now, calendar: calendar
        )
        #expect(buckets.count == 4) // Dec, Jan, Feb, Mar
        #expect(buckets.last?.end == date(2027, 4, 1, hour: 0))
    }

    @Test func nearestBucketPrefersTheOneHoldingTheDate() {
        let buckets = VolumeExplorer.buckets(
            for: [], grouping: .week, from: date(2027, 3, 1), through: now, calendar: calendar
        )
        // Sunday evening belongs to the week that started six days earlier, even though
        // the next week's start is closer.
        let picked = VolumeExplorer.bucket(nearest: date(2027, 3, 14, hour: 22), in: buckets)
        #expect(picked?.start == date(2027, 3, 8, hour: 0))
    }

    // MARK: Summary

    @Test func averageCountsEmptyBuckets() {
        let runs = [run(date(2027, 3, 2), meters: 30_000)]
        let buckets = VolumeExplorer.buckets(
            for: runs, grouping: .week, from: date(2027, 3, 1), through: now, calendar: calendar
        )
        let summary = VolumeExplorer.summary(
            metric: .distance, runs: runs, buckets: buckets, window: .month, from: date(2027, 3, 1, hour: 0), now: now
        )
        #expect(summary.total == 30_000)
        // 16 days 9 hours is 2.34 weeks, so the part week counts as part of one.
        let weeks = now.timeIntervalSince(date(2027, 3, 1, hour: 0)) / (7 * 86_400)
        #expect(abs(summary.averagePerBucket - 30_000 / weeks) < 0.001)
        #expect(summary.best?.start == date(2027, 3, 1, hour: 0))
    }

    @Test func comparesWithTheSameLengthJustBefore() {
        // Chart starts Monday 1 March 00:00; now is 17 March 09:00, so the previous
        // stretch is 16 days 9 hours back from 1 March: 12 Feb 15:00 onwards.
        let runs = [
            run(date(2027, 2, 10), meters: 99_000), // before the previous stretch
            run(date(2027, 2, 20), meters: 10_000), // previous
            run(date(2027, 3, 2), meters: 12_000),  // current
        ]
        let buckets = VolumeExplorer.buckets(
            for: runs, grouping: .week, from: date(2027, 3, 1), through: now, calendar: calendar
        )
        let summary = VolumeExplorer.summary(
            metric: .distance, runs: runs, buckets: buckets, window: .month, from: date(2027, 3, 1, hour: 0), now: now
        )
        #expect(summary.previousTotal == 10_000)
        #expect(abs((summary.change ?? 0) - 0.2) < 0.000_1)
    }

    @Test func noChangeWhenThePreviousStretchWasEmpty() {
        let runs = [run(date(2027, 3, 2))]
        let buckets = VolumeExplorer.buckets(
            for: runs, grouping: .week, from: date(2027, 3, 1), through: now, calendar: calendar
        )
        let summary = VolumeExplorer.summary(
            metric: .distance, runs: runs, buckets: buckets, window: .month, from: date(2027, 3, 1, hour: 0), now: now
        )
        #expect(summary.previousTotal == 0)
        #expect(summary.change == nil)
    }

    @Test func allTimeHasNothingToCompareWith() {
        let runs = [run(date(2027, 3, 2))]
        let buckets = VolumeExplorer.buckets(
            for: runs, grouping: .month, from: date(2027, 3, 2), through: now, calendar: calendar
        )
        let summary = VolumeExplorer.summary(
            metric: .runs, runs: runs, buckets: buckets, window: .all, from: date(2027, 3, 2), now: now
        )
        #expect(summary.previousTotal == nil)
        #expect(summary.total == 1)
    }

    @Test func totalCountsOnlyRunsInsideTheWindow() {
        // The first bar starts on Monday 1 March, but the window starts on Wednesday the
        // 3rd: Tuesday's run is drawn in the bar and left out of the headline.
        let start = date(2027, 3, 3, hour: 9)
        let runs = [run(date(2027, 3, 2), meters: 5_000), run(date(2027, 3, 4), meters: 8_000)]
        let buckets = VolumeExplorer.buckets(
            for: runs, grouping: .week, from: start, through: now, calendar: calendar
        )
        let summary = VolumeExplorer.summary(
            metric: .distance, runs: runs, buckets: buckets, window: .month, from: start, now: now
        )
        #expect(buckets.first?.meters == 13_000)
        #expect(summary.total == 8_000)
        #expect(summary.previousTotal == 5_000)
    }

    @Test func noBestWhenEveryBucketIsEmpty() {
        let buckets = VolumeExplorer.buckets(
            for: [], grouping: .week, from: date(2027, 3, 1), through: now, calendar: calendar
        )
        let summary = VolumeExplorer.summary(
            metric: .climb, runs: [], buckets: buckets, window: .month, from: date(2027, 3, 1, hour: 0), now: now
        )
        #expect(summary.best == nil)
        #expect(summary.averagePerBucket == 0)
    }
}
