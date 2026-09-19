import Foundation
import Testing
@testable import Stride

// MARK: - A9 training-nudge tests
//
// The streak nudge, the weekly recap and the missed-workout push. Every case pins a
// Gregorian UTC calendar and a fixed `now`, because all three decisions are about
// "which day is it and what time is it" and none of them should depend on the machine
// running the suite.

@MainActor
struct TrainingNudgePolicyTests {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-09-16 is a Wednesday; 2026-09-20 is a Sunday. Both are used below.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func run(on date: Date, meters: Double = 8_000, type: WorkoutType = .easy) -> RunWorkout {
        RunWorkout(date: date, distanceMeters: meters, durationSeconds: 2_400, workoutType: type)
    }

    private func summary(current: Int, isActiveToday: Bool) -> StreakGoalService.StreakSummary {
        StreakGoalService.StreakSummary(
            current: current,
            longest: max(current, 10),
            isActiveToday: isActiveToday
        )
    }

    /// A one-week plan whose workouts are given outright.
    private func makePlan(start: Date, workouts: [ScheduledWorkout], isActive: Bool = true) -> TrainingPlan {
        let plan = TrainingPlan(
            targetRace: .halfMarathon,
            goalTimeSeconds: 2 * 3_600,
            startDate: start,
            endDate: calendar.date(byAdding: .day, value: 84, to: start)!
        )
        plan.isActive = isActive
        let week = TrainingWeek(weekNumber: 1, startDate: start, phase: .base, targetDistanceKm: 40)
        week.workouts = workouts
        plan.weeks = [week]
        return plan
    }

    // MARK: Streak nudge

    @Test("A streak worth protecting with no run logged today produces a nudge")
    func streakNudgeFires() {
        let nudge = TrainingNudgePolicy.streakNudge(for: summary(current: 12, isActiveToday: false))

        #expect(nudge == StreakNudge(days: 12))
    }

    @Test("A run already logged today means there is nothing to protect")
    func streakNudgeSilentOnceTodayIsRun() {
        #expect(TrainingNudgePolicy.streakNudge(for: summary(current: 12, isActiveToday: true)) == nil)
    }

    /// Two days is not a streak, and prodding somebody about one is how a runner learns
    /// to swipe the app's notifications away without reading them.
    @Test("A streak shorter than the minimum is not nudged about")
    func shortStreakIsNotNudged() {
        let justUnder = TrainingNudgePolicy.minimumStreakToProtect - 1
        #expect(TrainingNudgePolicy.streakNudge(for: summary(current: justUnder, isActiveToday: false)) == nil)
        #expect(TrainingNudgePolicy.streakNudge(
            for: summary(current: TrainingNudgePolicy.minimumStreakToProtect, isActiveToday: false)
        ) != nil)
    }

    @Test("The nudge body carries the streak length, not just a warning")
    func streakBodyNamesTheNumber() {
        let body = NotificationService.streakNudgeBody(StreakNudge(days: 12))

        #expect(body.contains("12"))
    }

    // MARK: Missed-workout push

    /// Two consecutive past non-rest sessions left unlogged — the same bar
    /// `MissedWorkoutDetector` sets for the dashboard's recovery card.
    private func missedPlan(now: Date) -> TrainingPlan {
        let workouts = (1...3).map { offset in
            ScheduledWorkout(
                scheduledDate: calendar.date(byAdding: .day, value: -offset, to: now)!,
                workoutType: .easy
            )
        }
        return makePlan(start: calendar.date(byAdding: .day, value: -7, to: now)!, workouts: workouts)
    }

    @Test("A plan with a trailing streak of missed sessions produces the push")
    func missedWorkoutNudgeFires() {
        let now = date(2026, 9, 16, 18, 30)
        let info = TrainingNudgePolicy.missedWorkoutNudge(
            in: missedPlan(now: now), flaggedAt: nil, now: now, calendar: calendar
        )

        #expect(info?.count == 3)
    }

    /// The recovery card and the push share one dismissal. A runner who put the card
    /// away on Monday has answered the question; re-asking it on their Lock Screen on
    /// Wednesday is asking again through a louder channel.
    @Test("A card dismissed earlier this week suppresses the push")
    func missedWorkoutNudgeHonoursWeeklyDismissal() {
        let now = date(2026, 9, 16, 18, 30)          // Wednesday
        let monday = date(2026, 9, 14, 9, 0)         // same week
        let lastWeek = date(2026, 9, 11, 9, 0)       // the week before

        #expect(TrainingNudgePolicy.missedWorkoutNudge(
            in: missedPlan(now: now), flaggedAt: monday, now: now, calendar: calendar
        ) == nil)
        #expect(TrainingNudgePolicy.missedWorkoutNudge(
            in: missedPlan(now: now), flaggedAt: lastWeek, now: now, calendar: calendar
        ) != nil)
    }

    @Test("A plan that is no longer active is not pushed about")
    func inactivePlanIsNotNudgedAbout() {
        let now = date(2026, 9, 16, 18, 30)
        let plan = missedPlan(now: now)
        plan.isActive = false

        #expect(TrainingNudgePolicy.missedWorkoutNudge(
            in: plan, flaggedAt: nil, now: now, calendar: calendar
        ) == nil)
        #expect(TrainingNudgePolicy.missedWorkoutNudge(
            in: nil, flaggedAt: nil, now: now, calendar: calendar
        ) == nil)
    }

    @Test("The push body carries the count and the shift it is offering")
    func missedWorkoutBodyNamesCountAndShift() {
        let body = NotificationService.missedWorkoutNudgeBody(
            MissedWorkoutInfo(count: 3, firstMissedDate: date(2026, 9, 12), daysToShift: 4)
        )

        #expect(body.contains("3"))
        #expect(body.contains("4"))
    }

    // MARK: One nudge per evening

    /// The evening slot holds one push. A runner who is both mid-streak and behind their
    /// plan does not need two banners at 18:00 about the same evening.
    @Test("The streak wins the evening slot, because it is the one that expires tonight")
    func eveningSlotHoldsOneNudgeAndPrefersTheStreak() {
        let now = date(2026, 9, 16, 17, 0)
        let plan = missedPlan(now: now)

        let both = TrainingNudgePolicy.eveningNudge(
            streak: summary(current: 9, isActiveToday: false),
            plan: plan,
            now: now,
            calendar: calendar
        )
        #expect(both == .streak(StreakNudge(days: 9)))

        // With today's run already in, the slot falls to the missed-workout push.
        let missedOnly = TrainingNudgePolicy.eveningNudge(
            streak: summary(current: 9, isActiveToday: true),
            plan: plan,
            now: now,
            calendar: calendar
        )
        #expect(missedOnly?.kind == .missedWorkouts)
    }

    @Test("Nothing to say produces no nudge")
    func quietEveningProducesNothing() {
        let now = date(2026, 9, 16, 17, 0)
        let onPlan = makePlan(
            start: calendar.date(byAdding: .day, value: -7, to: now)!,
            workouts: [ScheduledWorkout(scheduledDate: now, workoutType: .easy)]
        )

        #expect(TrainingNudgePolicy.eveningNudge(
            streak: summary(current: 9, isActiveToday: true),
            plan: onPlan,
            now: now,
            calendar: calendar
        ) == nil)
    }

    // MARK: Delivery slots

    @Test("Before the slot the evening nudge is scheduled for it")
    func eveningNudgeSchedulesAheadOfTheSlot() {
        let now = date(2026, 9, 16, 9, 0)
        let delivery = TrainingNudgePolicy.eveningDelivery(now: now, calendar: calendar)

        #expect(delivery == .scheduled(date(2026, 9, 16, TrainingNudgePolicy.eveningNudgeHour, 0)))
    }

    /// The app was opened late. The message is still actionable, so it goes now rather
    /// than being dropped — the same call `HeatAdvisoryDelivery` makes.
    @Test("Between the slot and the cutoff the evening nudge is delivered immediately")
    func eveningNudgeDeliversImmediatelyAfterTheSlot() {
        let now = date(2026, 9, 16, TrainingNudgePolicy.eveningNudgeHour, 30)

        #expect(TrainingNudgePolicy.eveningDelivery(now: now, calendar: calendar) == .immediate)
    }

    /// A push telling somebody to go for a run at 22:30 is one they cannot act on.
    @Test("Past the cutoff the evening nudge is dropped rather than delivered late")
    func eveningNudgeSkippedPastCutoff() {
        let now = date(2026, 9, 16, TrainingNudgePolicy.eveningNudgeCutoffHour, 1)

        #expect(TrainingNudgePolicy.eveningDelivery(now: now, calendar: calendar) == .skip)
    }

    @Test("The weekly recap has a Sunday slot and no other")
    func weeklyRecapOnlyOnSunday() {
        let sundayMorning = date(2026, 9, 20, 9, 0)
        let wednesdayMorning = date(2026, 9, 16, 9, 0)

        #expect(calendar.component(.weekday, from: sundayMorning) == TrainingNudgePolicy.weeklyRecapWeekday)
        #expect(TrainingNudgePolicy.weeklyRecapDelivery(now: sundayMorning, calendar: calendar)
            == .scheduled(date(2026, 9, 20, TrainingNudgePolicy.weeklyRecapHour, 0)))
        #expect(TrainingNudgePolicy.weeklyRecapDelivery(now: wednesdayMorning, calendar: calendar) == .skip)
    }

    // MARK: Weekly recap contents

    @Test("The recap covers the Monday-anchored week containing Sunday evening")
    func weeklyRecapCoversTheWeekItIsSentIn() throws {
        let sundayEvening = date(2026, 9, 20, 19, 0)
        let runs = [
            run(on: date(2026, 9, 14, 7, 0), meters: 8_000),   // Monday, in
            run(on: date(2026, 9, 17, 7, 0), meters: 12_000),  // Thursday, in
            run(on: date(2026, 9, 20, 9, 0), meters: 16_000),  // Sunday, in
            run(on: date(2026, 9, 13, 9, 0), meters: 30_000)   // previous Sunday, out
        ]

        let recap = try #require(TrainingNudgePolicy.weeklyRecap(
            for: runs, goalMeters: 30_000, now: sundayEvening, calendar: calendar
        ))

        #expect(recap.weekStart == date(2026, 9, 14, 0, 0))
        #expect(recap.runCount == 3)
        #expect(recap.totalMeters == 36_000)
        #expect(recap.longestRunMeters == 16_000)
        #expect(recap.isGoalMet)
    }

    /// Every other weekly number in the app counts running only (N38); a recap that
    /// quietly includes the walk to the shops disagrees with the Progress tab it is
    /// summarising.
    @Test("Walks are left out of the recap")
    func weeklyRecapExcludesWalks() throws {
        let sundayEvening = date(2026, 9, 20, 19, 0)
        let runs = [
            run(on: date(2026, 9, 15, 7, 0), meters: 10_000),
            run(on: date(2026, 9, 16, 7, 0), meters: 5_000, type: .walk)
        ]

        let recap = try #require(TrainingNudgePolicy.weeklyRecap(
            for: runs, goalMeters: 30_000, now: sundayEvening, calendar: calendar
        ))

        #expect(recap.runCount == 1)
        #expect(recap.totalMeters == 10_000)
        #expect(!recap.isGoalMet)
        #expect(recap.remainingMeters == 20_000)
    }

    /// The streak nudge and the missed-workout push are the surfaces for not having run.
    /// A Sunday banner reading "0 runs, 0 km" is a scolding, not a summary.
    @Test("A week with no runs gets no recap")
    func emptyWeekGetsNoRecap() {
        let sundayEvening = date(2026, 9, 20, 19, 0)

        #expect(TrainingNudgePolicy.weeklyRecap(
            for: [], goalMeters: 30_000, now: sundayEvening, calendar: calendar
        ) == nil)
        #expect(TrainingNudgePolicy.weeklyRecap(
            for: [run(on: date(2026, 9, 13, 9, 0))], goalMeters: 30_000, now: sundayEvening, calendar: calendar
        ) == nil)
    }

    @Test("The recap body reads the week out, with the goal when one is set")
    func weeklyRecapBodyCarriesTheNumbers() {
        let met = NotificationService.weeklyRecapBody(
            WeeklyRecap(
                weekStart: date(2026, 9, 14),
                runCount: 4,
                totalMeters: 36_000,
                longestRunMeters: 16_000,
                goalMeters: 30_000
            ),
            unit: .metric
        )
        #expect(met.contains("4 runs"))
        #expect(met.contains("36.0 km"))
        #expect(met.contains("16.0 km"))
        #expect(met.contains("30.0 km"))

        let missed = NotificationService.weeklyRecapBody(
            WeeklyRecap(
                weekStart: date(2026, 9, 14),
                runCount: 2,
                totalMeters: 20_000,
                longestRunMeters: 12_000,
                goalMeters: 30_000
            ),
            unit: .metric
        )
        // 10 km short, and it says so rather than only reporting the total.
        #expect(missed.contains("10.0 km"))
    }

    /// `String(localized:)` extracts one key per call, so a single interpolated
    /// "\(count) runs" renders "1 runs" for the runner who went out once.
    @Test("A single-run week is not described as '1 runs'")
    func singleRunWeekReadsAsOneRun() {
        let body = NotificationService.weeklyRecapBody(
            WeeklyRecap(
                weekStart: date(2026, 9, 14),
                runCount: 1,
                totalMeters: 10_000,
                longestRunMeters: 10_000,
                goalMeters: 0
            ),
            unit: .metric
        )

        #expect(body.contains("1 run,"))
        #expect(!body.contains("1 runs"))
        // No goal set, so there is nothing to compare against and the sentence is omitted.
        #expect(!body.contains("goal"))
    }

    @Test("The recap follows the unit preference")
    func weeklyRecapBodyRespectsImperial() {
        let body = NotificationService.weeklyRecapBody(
            WeeklyRecap(
                weekStart: date(2026, 9, 14),
                runCount: 3,
                totalMeters: 32_186.88,   // 20 miles
                longestRunMeters: 16_093.44,
                goalMeters: 48_280.32
            ),
            unit: .imperial
        )

        #expect(body.contains("20.0 mi"))
        #expect(!body.contains("km"))
    }

    // MARK: Delivery log

    /// The log exists for the `.immediate` branch: a scheduled request replaces itself by
    /// identifier, but a banner already delivered cannot be taken back, so a runner who
    /// opens the app twice this evening must not be told twice.
    @Test("A handled period is remembered, and the next one is not")
    func deliveryLogGatesRepeatDelivery() throws {
        let suiteName = "TrainingNudgeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tonight = TrainingNudgePolicy.period(
            for: .streak, now: date(2026, 9, 16, 18, 30), calendar: calendar
        )
        let tomorrow = TrainingNudgePolicy.period(
            for: .streak, now: date(2026, 9, 17, 18, 30), calendar: calendar
        )

        #expect(!TrainingNudgeLog.hasHandled(.streak, period: tonight, in: defaults))
        TrainingNudgeLog.markHandled(.streak, period: tonight, in: defaults)
        #expect(TrainingNudgeLog.hasHandled(.streak, period: tonight, in: defaults))
        #expect(!TrainingNudgeLog.hasHandled(.streak, period: tomorrow, in: defaults))
        // One kind's mark says nothing about another's.
        #expect(!TrainingNudgeLog.hasHandled(.missedWorkouts, period: tonight, in: defaults))
    }

    @Test("The recap's period is the week, so it is handled once per week")
    func recapPeriodIsTheWeek() {
        let sunday = TrainingNudgePolicy.period(
            for: .weeklyRecap, now: date(2026, 9, 20, 19, 30), calendar: calendar
        )
        let wednesday = TrainingNudgePolicy.period(
            for: .weeklyRecap, now: date(2026, 9, 16, 9, 0), calendar: calendar
        )

        #expect(sunday == date(2026, 9, 14, 0, 0))
        #expect(sunday == wednesday)
    }

    /// Switching the setting off and straight back on has to be able to nudge again the
    /// same evening; leaving today's mark behind would make it silent until tomorrow.
    @Test("Clearing the log forgets every kind")
    func clearingTheLogForgetsEveryKind() throws {
        let suiteName = "TrainingNudgeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tonight = TrainingNudgePolicy.period(
            for: .streak, now: date(2026, 9, 16, 18, 30), calendar: calendar
        )
        defaults.set("keep", forKey: "unrelated.key")
        for kind in TrainingNudgeKind.allCases {
            TrainingNudgeLog.markHandled(kind, period: tonight, in: defaults)
        }

        TrainingNudgeLog.clearAll(in: defaults)

        for kind in TrainingNudgeKind.allCases {
            #expect(!TrainingNudgeLog.hasHandled(kind, period: tonight, in: defaults))
        }
        #expect(defaults.string(forKey: "unrelated.key") == "keep")
    }
}
