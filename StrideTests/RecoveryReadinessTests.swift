import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers `RecoveryReadings`' shaping helpers, `RecoveryReadiness`' thresholds, and the
/// readiness coach card built on them (B7).
///
/// Every component is pinned at both ends of its scale, because the score is advice about
/// whether to train hard and a threshold that silently moved would change that advice.
@MainActor
struct RecoveryReadinessTests {

    /// Fixed anchor: 2023-11-14 22:13:20 UTC, a Tuesday.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var today: Date { calendar.startOfDay(for: now) }

    // MARK: Fixtures

    /// `baselineCount` days at `baseline` ending the day before `latestDaysAgo`, then one
    /// day at `latest`.
    private func days(
        baseline: Double,
        latest: Double,
        baselineCount: Int = 10,
        latestDaysAgo: Int = 0
    ) -> [RecoveryReadings.Day] {
        let latestDay = calendar.date(byAdding: .day, value: -latestDaysAgo, to: today)!
        let prior = (1...baselineCount).map { offset in
            RecoveryReadings.Day(
                day: calendar.date(byAdding: .day, value: -offset, to: latestDay)!,
                value: baseline
            )
        }
        return prior.reversed() + [RecoveryReadings.Day(day: latestDay, value: latest)]
    }

    private func makeRun(in context: ModelContext, daysAgo: Double, durationSeconds: Double = 3_600) -> RunWorkout {
        let run = RunWorkout(
            date: now.addingTimeInterval(-daysAgo * 86_400),
            distanceMeters: 10_000,
            durationSeconds: durationSeconds,
            workoutType: .easy
        )
        context.insert(run)
        return run
    }

    private func evaluate(_ readings: RecoveryReadings, runs: [RunWorkout] = []) -> RecoveryReadiness? {
        RecoveryReadiness.evaluate(readings: readings, runs: runs, now: now, calendar: calendar)
    }

    // MARK: - Shaping

    @Test("Samples are grouped into per-day means, oldest first, ignoring non-positive values")
    func dailyMeans() {
        let morning = today.addingTimeInterval(6 * 3_600)
        let yesterday = today.addingTimeInterval(-18 * 3_600)
        let days = RecoveryReadings.dailyMeans([
            (date: morning, value: 40),
            (date: morning.addingTimeInterval(600), value: 60),
            (date: morning.addingTimeInterval(1_200), value: 0),
            (date: yesterday, value: 55)
        ], calendar: calendar)

        #expect(days.count == 2)
        #expect(days[0].day == calendar.startOfDay(for: yesterday))
        #expect(days[0].value == 55)
        #expect(days[1].day == today)
        #expect(days[1].value == 50)
    }

    @Test("Overlapping sleep from two sources is counted once, and clipped to the window")
    func mergedSleep() {
        let window = DateInterval(start: today, end: today.addingTimeInterval(12 * 3_600))
        let hour: TimeInterval = 3_600
        let intervals = [
            // Before the window: only the last hour counts.
            DateInterval(start: today.addingTimeInterval(-hour), end: today.addingTimeInterval(hour)),
            // Overlaps the first.
            DateInterval(start: today.addingTimeInterval(0.5 * hour), end: today.addingTimeInterval(3 * hour)),
            // Separate, after a gap.
            DateInterval(start: today.addingTimeInterval(4 * hour), end: today.addingTimeInterval(6 * hour)),
            // Wholly inside the previous one.
            DateInterval(start: today.addingTimeInterval(4.5 * hour), end: today.addingTimeInterval(5 * hour))
        ]
        #expect(RecoveryReadings.mergedDuration(of: intervals, within: window) == 5 * hour)
        #expect(RecoveryReadings.mergedDuration(of: [], within: window) == 0)
    }

    @Test("Last night runs from 18:00 the evening before to now, whatever time it is read")
    func lastNightWindow() {
        let morning = today.addingTimeInterval(7 * 3_600)
        let window = RecoveryReadings.lastNightWindow(endingAt: morning, calendar: calendar)
        #expect(window.start == today.addingTimeInterval(-6 * 3_600))
        #expect(window.end == morning)

        let afternoon = RecoveryReadings.lastNightWindow(endingAt: now, calendar: calendar)
        #expect(afternoon.start == window.start)
    }

    // MARK: - When there is nothing to say

    @Test("No body signal means no readiness, even with a heavy week of runs")
    func loadAloneIsNotReadiness() {
        let context = TestStore.makeContext()
        let runs = (0..<10).map { makeRun(in: context, daysAgo: Double($0) + 0.5) }
        #expect(evaluate(RecoveryReadings(), runs: runs) == nil)
    }

    @Test("HRV and resting HR need seven days of baseline before they are scored")
    func baselineMinimum() {
        let short = RecoveryReadings(heartRateVariability: days(baseline: 60, latest: 30, baselineCount: 6))
        #expect(evaluate(short) == nil)

        let enough = RecoveryReadings(heartRateVariability: days(baseline: 60, latest: 30, baselineCount: 7))
        #expect(evaluate(enough)?.component(.heartRateVariability) != nil)
    }

    @Test("A latest reading older than yesterday does not describe this morning")
    func staleReading() {
        let yesterday = RecoveryReadings(heartRateVariability: days(baseline: 60, latest: 30, latestDaysAgo: 1))
        #expect(evaluate(yesterday) != nil)

        let older = RecoveryReadings(heartRateVariability: days(baseline: 60, latest: 30, latestDaysAgo: 2))
        #expect(evaluate(older) == nil)
    }

    // MARK: - Components at both ends

    @Test(
        "HRV: no penalty to 5% under the runner's norm, full penalty from 30% under",
        arguments: [(60.0, 1.0), (57.0, 1.0), (42.0, 0.0), (36.0, 0.0), (49.5, 0.5)]
    )
    func hrvScale(latest: Double, expected: Double) throws {
        let readings = RecoveryReadings(heartRateVariability: days(baseline: 60, latest: latest))
        let readiness = try #require(evaluate(readings))
        let hrv = try #require(readiness.component(.heartRateVariability))
        #expect(abs(hrv.recovery - expected) < 0.0001)
    }

    @Test(
        "Resting HR: no penalty to 2 bpm up, full penalty from 8 bpm up",
        arguments: [(50.0, 1.0), (52.0, 1.0), (55.0, 0.5), (58.0, 0.0), (45.0, 1.0)]
    )
    func restingScale(latest: Double, expected: Double) throws {
        let readings = RecoveryReadings(restingHeartRate: days(baseline: 50, latest: latest))
        let readiness = try #require(evaluate(readings))
        let resting = try #require(readiness.component(.restingHeartRate))
        #expect(abs(resting.recovery - expected) < 0.0001)
        #expect(resting.reading == latest - 50)
    }

    @Test(
        "Sleep: full marks from 7.5 h, none at 5 h or less",
        arguments: [(8.0, 1.0), (7.5, 1.0), (6.25, 0.5), (5.0, 0.0), (3.0, 0.0)]
    )
    func sleepScale(hours: Double, expected: Double) throws {
        let readiness = try #require(evaluate(RecoveryReadings(lastNightSleepSeconds: hours * 3_600)))
        let sleep = try #require(readiness.component(.sleep))
        #expect(abs(sleep.recovery - expected) < 0.0001)
        #expect(readiness.score == Int((expected * 100).rounded()))
    }

    @Test("Load compares seven days of running time to the four-week weekly average")
    func loadRatio() throws {
        let context = TestStore.makeContext()
        let steady = [2.0, 9, 16, 23].map { makeRun(in: context, daysAgo: $0) }
        #expect(RecoveryReadiness.loadRatio(runs: steady, now: now) == 1.0)

        // Two extra hours this week: 3 h against a 1.5 h weekly average.
        let spike = steady + [1.0, 3].map { makeRun(in: context, daysAgo: $0) }
        #expect(RecoveryReadiness.loadRatio(runs: spike, now: now) == 2.0)

        let readiness = try #require(evaluate(RecoveryReadings(lastNightSleepSeconds: 8 * 3_600), runs: spike))
        #expect(readiness.component(.load)?.recovery == 0)
    }

    @Test("Load is not scored on a month of almost no running")
    func loadNeedsABase() {
        let context = TestStore.makeContext()
        let sparse = [makeRun(in: context, daysAgo: 1, durationSeconds: 1_800)]
        // 30 min across four weeks is 7.5 min a week, under the 60-minute floor.
        #expect(RecoveryReadiness.loadRatio(runs: sparse, now: now) == nil)
    }

    @Test("The score is the weighted mean of whichever components are present")
    func weightedScore() throws {
        // HRV fully recovered (0.35), sleep fully penalised (0.25): 0.35 / 0.60.
        let readings = RecoveryReadings(
            heartRateVariability: days(baseline: 60, latest: 60),
            lastNightSleepSeconds: 4 * 3_600
        )
        let readiness = try #require(evaluate(readings))
        #expect(readiness.score == 58)
        #expect(readiness.drivers.map(\.kind) == [.sleep])
    }

    @Test("Readiness stops describing today at the next midnight after its newest reading")
    func validity() throws {
        let readiness = try #require(evaluate(RecoveryReadings(lastNightSleepSeconds: 8 * 3_600)))
        #expect(readiness.validUntil == calendar.date(byAdding: .day, value: 1, to: today))
    }

    // MARK: - Coach prompt

    @Test("The coach prompt carries the score, its meaning, and every component's reading")
    func promptSummary() throws {
        let readings = RecoveryReadings(
            heartRateVariability: days(baseline: 60, latest: 45),
            restingHeartRate: days(baseline: 50, latest: 54),
            lastNightSleepSeconds: 6 * 3_600
        )
        let summary = try #require(evaluate(readings)).promptSummary
        #expect(summary.hasPrefix("Readiness this morning: "))
        #expect(summary.contains("under 60, so today should be easy or a rest day"))
        #expect(summary.contains("Heart-rate variability 25% under their 4-week norm"))
        #expect(summary.contains("resting heart rate 4 bpm above their 4-week norm"))
        #expect(summary.contains("slept 6.0 hours last night"))

        let rested = try #require(evaluate(RecoveryReadings(lastNightSleepSeconds: 8 * 3_600)))
        #expect(rested.promptSummary.contains("60 or above, so the plan can stand"))
        #expect(rested.promptSummary.contains("Slept 8.0 hours"))
    }

    // MARK: - The card

    private func cardContext(
        readings: RecoveryReadings?,
        nextSession: ScheduledWorkout? = nil
    ) -> SmartCoachCards.Context {
        SmartCoachCards.Context(
            nextSession: nextSession,
            recentRuns: [],
            profile: nil,
            dayState: .noPlan,
            unit: .metric,
            recoveryReadings: readings,
            now: now,
            calendar: calendar
        )
    }

    @Test("The card fires under 60 and stays quiet at 60 and above")
    func cardThreshold() {
        // 6.25 h of sleep scores 50; 7 h scores 80.
        let short = RecoveryReadings(lastNightSleepSeconds: 6.25 * 3_600)
        let low = SmartCoachCards.readinessCard(cardContext(readings: short))
        #expect(low?.kind == .readiness)
        #expect(low?.tone == .caution)

        let enough = RecoveryReadings(lastNightSleepSeconds: 7 * 3_600)
        let fine = SmartCoachCards.readinessCard(cardContext(readings: enough))
        #expect(fine == nil)

        #expect(SmartCoachCards.readinessCard(cardContext(readings: nil)) == nil)
    }

    @Test("A deeply under-recovered morning outranks every routine card")
    func cardScoreSaturates() throws {
        let readings = RecoveryReadings(
            heartRateVariability: days(baseline: 60, latest: 30),
            restingHeartRate: days(baseline: 50, latest: 60),
            lastNightSleepSeconds: 4 * 3_600
        )
        let card = try #require(SmartCoachCards.readinessCard(cardContext(readings: readings)))
        #expect(card.score == 1)
        #expect(card.message.contains("heart-rate variability is 50% under"))
        #expect(card.message.contains("resting heart rate is 10 bpm above"))
        #expect(card.message.contains("slept 4 h"))
        #expect(card.derivation?.hasPrefix("Readiness 0/100") == true)
        #expect(card.expiresAt == calendar.date(byAdding: .day, value: 1, to: today))
    }

    @Test("A demanding next session is named in the advice")
    func cardNamesTheSession() throws {
        let context = TestStore.makeContext()
        let tempo = ScheduledWorkout(
            scheduledDate: now.addingTimeInterval(86_400),
            workoutType: .tempo,
            targetDistanceMeters: 10_000
        )
        context.insert(tempo)
        let readings = RecoveryReadings(lastNightSleepSeconds: 5 * 3_600)

        let before = try #require(SmartCoachCards.readinessCard(cardContext(readings: readings, nextSession: tempo)))
        #expect(before.message.contains("tempo"))

        let none = try #require(SmartCoachCards.readinessCard(cardContext(readings: readings)))
        #expect(!none.message.contains("tempo"))
    }
}
