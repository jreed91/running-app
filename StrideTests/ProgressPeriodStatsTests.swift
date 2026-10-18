import Foundation
import Testing
@testable import Stride

/// Covers `ProgressPeriodStats`, the Progress tab's period arithmetic. It ran in
/// `ProgressDashboardView`'s body-evaluated properties until now (D1) — the least
/// tested code in the app, and the kind whose failures are invisible: a wrong
/// denominator still renders a plausible number.
@MainActor
struct ProgressPeriodStatsTests {

    private let now = Calendar.current.date(
        from: DateComponents(year: 2027, month: 3, day: 15, hour: 9)
    ) ?? .now

    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    private func run(
        daysAgo days: Int,
        meters: Double = 10_000,
        seconds: Double = 3_000,
        type: WorkoutType = .easy,
        heartRate: Double? = nil,
        elevation: Double? = nil
    ) -> RunWorkout {
        let workout = RunWorkout(
            date: daysAgo(days),
            distanceMeters: meters,
            durationSeconds: seconds,
            workoutType: type
        )
        workout.averageHeartRate = heartRate
        workout.elevationGainMeters = elevation
        return workout
    }

    // MARK: Range

    @Test("The range is a rolling window, and its edge is inclusive")
    func rangeIsRolling() {
        let runs = [run(daysAgo: 0), run(daysAgo: 29), run(daysAgo: 31)]

        let inRange = ProgressPeriodStats.runs(in: runs, withinDays: 30, now: now)

        #expect(inRange.count == 2)
        #expect(inRange.allSatisfy { $0.date >= daysAgo(30) })
    }

    @Test("An empty period yields the empty summary rather than zeroed averages")
    func emptyPeriodIsEmpty() {
        let summary = ProgressPeriodStats.summary(for: [])

        #expect(summary == .empty)
        #expect(summary.runCount == 0)
        #expect(summary.averagePaceSecondsPerKm == nil)
        #expect(summary.averageHeartRate == nil)
    }

    // MARK: Averages

    @Test("Average pace is distance-weighted, not a mean of each run's pace")
    func paceIsDistanceWeighted() {
        // 10 km at 5:00/km and 2 km at 7:00/km. Σtime ÷ Σdistance is 5:20/km;
        // an unweighted mean of the two paces would say 6:00/km.
        let summary = ProgressPeriodStats.summary(for: [
            run(daysAgo: 1, meters: 10_000, seconds: 3_000),
            run(daysAgo: 2, meters: 2_000, seconds: 840)
        ])

        #expect(abs((summary.averagePaceSecondsPerKm ?? 0) - 320) < 0.5)
    }

    @Test("Heart rate averages over the runs that recorded it, not over every run")
    func heartRateIgnoresRunsWithout() {
        // Dividing by the run count instead of the sample count would give 100.
        let summary = ProgressPeriodStats.summary(for: [
            run(daysAgo: 1, heartRate: 150),
            run(daysAgo: 2, heartRate: 150),
            run(daysAgo: 3, heartRate: nil)
        ])

        #expect(summary.averageHeartRate == 150)
    }

    @Test("Elevation averages only over runs with a positive gain")
    func elevationIgnoresZeroAndMissing() {
        // A stored 0 is indistinguishable from "the watch reported nothing", so both
        // are excluded rather than halving the average.
        let summary = ProgressPeriodStats.summary(for: [
            run(daysAgo: 1, elevation: 200),
            run(daysAgo: 2, elevation: 0),
            run(daysAgo: 3, elevation: nil)
        ])

        #expect(summary.averageElevationGainMeters == 200)
    }

    @Test("A period of runs with no distance reports no pace rather than 0:00")
    func zeroDistanceReportsNoPace() {
        let summary = ProgressPeriodStats.summary(for: [run(daysAgo: 1, meters: 0, seconds: 600)])

        #expect(summary.runCount == 1)
        #expect(summary.averagePaceSecondsPerKm == nil)
    }

    @Test("Total distance sums every run in the period")
    func totalDistanceSums() {
        let summary = ProgressPeriodStats.summary(for: [
            run(daysAgo: 1, meters: 10_000),
            run(daysAgo: 2, meters: 5_500)
        ])

        #expect(summary.totalDistanceMeters == 15_500)
    }

    // MARK: VDOT series

    @Test("Only quality efforts contribute a VDOT sample")
    func vdotSamplesQualityOnly() {
        let samples = ProgressPeriodStats.vdotSamples(for: [
            run(daysAgo: 1, type: .easy),
            run(daysAgo: 2, type: .longRun),
            run(daysAgo: 3, type: .tempo)
        ])

        // Easy and long runs are paced below capability; sampling them drags the trend down.
        #expect(samples.count == 1)
        #expect(samples.first?.date == daysAgo(3))
    }

    @Test("Samples are ordered oldest first, so the latest VDOT is the most recent one")
    func vdotSamplesAreChronological() {
        // Newest-first input, matching a reversed query, must not make the oldest
        // sample read as the runner's current fitness.
        let newest = run(daysAgo: 1, meters: 10_000, seconds: 2_400, type: .tempo)
        let oldest = run(daysAgo: 40, meters: 10_000, seconds: 3_600, type: .tempo)

        let samples = ProgressPeriodStats.vdotSamples(for: [newest, oldest])

        #expect(samples.count == 2)
        #expect(samples.first?.date == daysAgo(40))
        #expect(samples.last?.date == daysAgo(1))

        let summary = ProgressPeriodStats.summary(for: [newest, oldest])
        #expect(summary.latestVDOT == samples.last?.vdot)
        // The faster recent effort implies the higher VDOT of the two.
        #expect((summary.latestVDOT ?? 0) > (samples.first?.vdot ?? 0))
    }

    @Test("A period with no quality efforts reports no VDOT at all")
    func noQualityEffortsReportsNoVDOT() {
        let summary = ProgressPeriodStats.summary(for: [run(daysAgo: 1, type: .easy)])

        #expect(summary.averageVDOT == nil)
        #expect(summary.latestVDOT == nil)
        #expect(summary.runCount == 1)
    }

    // MARK: Weekly buckets

    @Test("Runs in the same week are totalled into one bucket, in metres")
    func weeklyBucketsTotalByWeek() {
        let monday = Calendar.current.date(
            from: DateComponents(year: 2027, month: 3, day: 15, hour: 9)
        ) ?? .now
        let wednesday = monday.addingTimeInterval(2 * 86_400)
        let followingMonday = monday.addingTimeInterval(7 * 86_400)

        let buckets = ProgressPeriodStats.weeklyDistances(for: [
            RunWorkout(date: monday, distanceMeters: 8_000, durationSeconds: 2_400),
            RunWorkout(date: wednesday, distanceMeters: 12_000, durationSeconds: 3_600),
            RunWorkout(date: followingMonday, distanceMeters: 5_000, durationSeconds: 1_500)
        ])

        #expect(buckets.count == 2)
        #expect(buckets.first?.meters == 20_000)
        #expect(buckets.last?.meters == 5_000)
        // Oldest week first, so the chart reads left to right.
        #expect((buckets.first?.weekStart ?? .now) < (buckets.last?.weekStart ?? .now))
    }

    @Test("Buckets are keyed by the week's Monday, matching the rest of the app's weeks")
    func weeklyBucketsStartOnMonday() {
        let wednesday = Calendar.current.date(
            from: DateComponents(year: 2027, month: 3, day: 17, hour: 9)
        ) ?? .now

        let buckets = ProgressPeriodStats.weeklyDistances(for: [
            RunWorkout(date: wednesday, distanceMeters: 8_000, durationSeconds: 2_400)
        ])

        #expect(buckets.first?.weekStart == wednesday.startOfWeek)
    }

    @Test("No runs means no buckets, which the chart shows as an empty state")
    func noRunsMeansNoBuckets() {
        #expect(ProgressPeriodStats.weeklyDistances(for: []).isEmpty)
    }

    // MARK: Easy pace trend

    /// Paces come from `duration / distance * 1000`, which isn't exact in binary.
    private func approx(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 0.001
    }

    @Test("Only easy and long runs feed the pace trend")
    func easyPaceTrendSkipsQualitySessions() {
        let trend = ProgressPeriodStats.easyPaceTrend(for: [
            run(daysAgo: 1, seconds: 3_300, type: .easy),
            run(daysAgo: 2, seconds: 2_400, type: .interval),
            run(daysAgo: 3, seconds: 2_500, type: .tempo),
            run(daysAgo: 4, seconds: 2_300, type: .race),
            run(daysAgo: 5, seconds: 3_600, type: .longRun),
            run(daysAgo: 6, seconds: 3_000, type: .walk)
        ])

        #expect(trend.runs.map(\.workoutType) == [.longRun, .easy])
        // Oldest first, so the chart and the halves read left to right.
        #expect(approx(trend.runs.first?.paceSecondsPerKm, 360))
    }

    @Test("Each week's point is the median, so one slow run doesn't drag it")
    func easyPaceWeekIsMedian() {
        let monday = Calendar.current.date(from: DateComponents(year: 2027, month: 3, day: 15, hour: 9)) ?? .now
        let runs = [300.0, 310, 420].enumerated().map { offset, secondsPerKm in
            RunWorkout(
                date: monday.addingTimeInterval(Double(offset) * 86_400),
                distanceMeters: 10_000,
                durationSeconds: secondsPerKm * 10
            )
        }

        let trend = ProgressPeriodStats.easyPaceTrend(for: runs)

        #expect(trend.weeks.count == 1)
        #expect(approx(trend.weeks.first?.paceSecondsPerKm, 310))
        #expect(approx(trend.latestWeekPaceSecondsPerKm, 310))
    }

    @Test("The change compares the later half of the runs with the earlier half; negative is faster")
    func easyPaceChangeIsLaterMinusEarlier() {
        // Four weeks, one run each, getting 10 s/km faster every week.
        let trend = ProgressPeriodStats.easyPaceTrend(for: [
            run(daysAgo: 21, seconds: 3_300),
            run(daysAgo: 14, seconds: 3_200),
            run(daysAgo: 7, seconds: 3_100),
            run(daysAgo: 0, seconds: 3_000)
        ])

        // Earlier median (330 + 320) / 2 = 325, later (310 + 300) / 2 = 305.
        #expect(trend.weeks.count == 4)
        #expect(approx(trend.changeSecondsPerKm, -20))
    }

    @Test("No change is claimed off too few runs or too few weeks")
    func easyPaceChangeNeedsEnoughData() {
        let threeRuns = ProgressPeriodStats.easyPaceTrend(for: [
            run(daysAgo: 21, seconds: 3_300),
            run(daysAgo: 14, seconds: 3_200),
            run(daysAgo: 0, seconds: 3_000)
        ])
        #expect(threeRuns.changeSecondsPerKm == nil)

        let monday = Calendar.current.date(from: DateComponents(year: 2027, month: 3, day: 15, hour: 9)) ?? .now
        let oneWeek = ProgressPeriodStats.easyPaceTrend(for: (0..<5).map {
            RunWorkout(
                date: monday.addingTimeInterval(Double($0) * 86_400),
                distanceMeters: 10_000,
                durationSeconds: 3_000
            )
        })
        #expect(oneWeek.changeSecondsPerKm == nil)
    }

    @Test("A period with no easy runs has an empty trend")
    func easyPaceTrendEmpty() {
        let trend = ProgressPeriodStats.easyPaceTrend(for: [run(daysAgo: 1, type: .tempo)])

        #expect(trend.runs.isEmpty)
        #expect(trend.weeks.isEmpty)
        #expect(trend.latestWeekPaceSecondsPerKm == nil)
    }
}
