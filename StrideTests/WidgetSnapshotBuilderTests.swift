import Foundation
import SwiftData
import Testing
@testable import Stride

// MARK: - Widget snapshot tests
//
// Everything the Home Screen and Lock Screen widgets show is decided by
// `WidgetSnapshotBuilder` and rendered from the resulting value — the extension itself
// does no logic beyond reading a file and asking the value how its dates read today.
// That makes this the whole of the widgets' testable surface, so it is tested here
// rather than trusted to a screenshot.
//
// Every case pins a UTC calendar and a fixed `now`, the way `StreakGoalServiceTests` does:
// "Today", Monday-anchored weeks, and a race countdown are all day-bucketing, and all
// three would otherwise move with the machine's time zone.

@MainActor
struct WidgetSnapshotBuilderTests {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Noon on Thursday 2026-07-23. Mid-day so nothing straddles a day boundary.
    private var now: Date { day(2026, 7, 23) }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func offset(_ days: Int, from date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)!
    }

    /// Monday-anchored start of week under the pinned calendar, mirroring the service.
    private func startOfWeek(_ date: Date) -> Date {
        var cal = calendar
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps)!
    }

    // MARK: Fixtures

    /// Containers are parked here rather than discarded.
    ///
    /// Every call site is `makePlan(in: makeContext(), …)`, so returning only the context
    /// let the `AppContainer` — and with it the store — be released while `makePlan` was
    /// still inserting into that context. SwiftData traps on iOS 27 when that happens, and
    /// a trap takes the whole test host down, so every test still queued in the process is
    /// reported as failed too.
    ///
    /// Holding them for the process lifetime is deliberate and cheap: a probe built and
    /// saved through 400 `AppContainer.preview()` instances with no growth in open file
    /// descriptors, so there is nothing to reclaim here.
    private static var retainedContainers: [AppContainer] = []

    /// Model graphs are built inside a real (in-memory) context, the way
    /// `ScheduledDayResolverTests` does it: the builder walks `plan.weeks` and
    /// `week.workouts`, and those inverse relationships are only maintained for inserted
    /// objects.
    private func makeContext() -> ModelContext {
        let container = AppContainer.preview()
        Self.retainedContainers.append(container)
        return container.modelContainer.mainContext
    }

    private func run(on date: Date, meters: Double = 5_000) -> RunWorkout {
        RunWorkout(date: date, distanceMeters: meters, durationSeconds: 1_500, workoutType: .easy)
    }

    private struct Session {
        var date: Date
        var type: WorkoutType = .tempo
        var meters: Double? = 8_000
        var completed = false
        var notes: String?
        var paceBounds: (Double, Double)?
    }

    @discardableResult
    private func makePlan(
        in context: ModelContext,
        sessions: [Session] = [],
        isActive: Bool = true,
        raceName: String? = nil,
        raceDate: Date? = nil,
        phase: TrainingPhase = .build,
        weekNumber: Int = 6,
        weekStart: Date? = nil
    ) -> TrainingPlan {
        let start = weekStart ?? startOfWeek(now)
        let plan = TrainingPlan(
            targetRace: .marathon,
            goalTimeSeconds: 3 * 3_600 + 29 * 60,
            raceName: raceName,
            raceDate: raceDate,
            startDate: start,
            endDate: offset(6, from: start)
        )
        plan.isActive = isActive
        context.insert(plan)

        let week = TrainingWeek(
            weekNumber: weekNumber,
            startDate: start,
            phase: phase,
            targetDistanceKm: 50
        )
        context.insert(week)
        week.plan = plan

        for session in sessions {
            let workout = ScheduledWorkout(
                scheduledDate: session.date,
                workoutType: session.type,
                targetDistanceMeters: session.meters,
                targetPaceLowerBound: session.paceBounds?.0,
                targetPaceUpperBound: session.paceBounds?.1,
                notes: session.notes
            )
            workout.isCompleted = session.completed
            context.insert(workout)
            workout.week = week
        }

        try? context.save()
        return plan
    }

    // MARK: - Next workout

    @Test("Today's outstanding session is the card")
    func todaysSessionIsChosen() {
        let plan = makePlan(in: makeContext(), sessions: [
            Session(date: now, type: .tempo),
            Session(date: offset(1, from: now), type: .easy)
        ])

        let card = WidgetSnapshotBuilder.nextWorkout(in: plan, unit: .metric, now: now, calendar: calendar)

        #expect(card?.title == WorkoutType.tempo.localizedName)
        #expect(card?.detail == "8.0 km")
        #expect(card?.dayLabel(asOf: now, calendar: calendar) == "Today")
        #expect(card?.isRest == false)
    }

    @Test("A session the plan has already passed still shows, labelled Overdue")
    func overdueSessionIsChosenBeforeFutureOnes() {
        let plan = makePlan(in: makeContext(), sessions: [
            Session(date: offset(-2, from: now), type: .interval),
            Session(date: offset(2, from: now), type: .easy)
        ])

        let card = WidgetSnapshotBuilder.nextWorkout(in: plan, unit: .metric, now: now, calendar: calendar)

        #expect(card?.title == WorkoutType.interval.localizedName)
        #expect(card?.dayLabel(asOf: now, calendar: calendar) == "Overdue")
    }

    @Test("A completed session is skipped in favour of the next one")
    func completedSessionIsSkipped() {
        let plan = makePlan(in: makeContext(), sessions: [
            Session(date: now, type: .tempo, completed: true),
            Session(date: offset(1, from: now), type: .longRun, meters: 20_000)
        ])

        let card = WidgetSnapshotBuilder.nextWorkout(in: plan, unit: .metric, now: now, calendar: calendar)

        #expect(card?.title == WorkoutType.longRun.localizedName)
        #expect(card?.detail == "20.0 km")
        #expect(card?.dayLabel(asOf: now, calendar: calendar) == "Tomorrow")
    }

    /// "The plan says rest" and "there is no plan" read the same on a widget and mean very
    /// different things — the distinction `ScheduledDayResolver.DayState` draws (N23).
    @Test("A scheduled rest day is a card, not an absence")
    func restDayIsRepresented() {
        let plan = makePlan(in: makeContext(), sessions: [
            Session(date: now, type: .rest, meters: nil),
            Session(date: offset(2, from: now), type: .easy)
        ])

        let card = WidgetSnapshotBuilder.nextWorkout(in: plan, unit: .metric, now: now, calendar: calendar)

        #expect(card?.isRest == true)
        #expect(card?.detail == nil)
        #expect(card?.paceTarget == nil)
    }

    /// Retired plans keep their future days — they are preserved as history, not deleted —
    /// so a widget must not advertise a workout from a plan the runner replaced.
    @Test("An inactive plan contributes nothing")
    func inactivePlanIsIgnored() {
        let plan = makePlan(in: makeContext(), sessions: [Session(date: now)], isActive: false)

        #expect(WidgetSnapshotBuilder.nextWorkout(in: plan, unit: .metric, now: now, calendar: calendar) == nil)
    }

    @Test("Target pace is formatted as a range in the runner's own unit")
    func paceTargetUsesUnitPreference() {
        let plan = makePlan(in: makeContext(), sessions: [
            Session(date: now, paceBounds: (272, 285))   // 4:32 – 4:45 /km
        ])

        let metric = WidgetSnapshotBuilder.nextWorkout(in: plan, unit: .metric, now: now, calendar: calendar)
        let imperial = WidgetSnapshotBuilder.nextWorkout(in: plan, unit: .imperial, now: now, calendar: calendar)

        #expect(metric?.paceTarget == "4:32–4:45 /km")
        #expect(metric?.detail == "8.0 km")
        #expect(imperial?.paceTarget?.hasSuffix("/mi") == true)
        #expect(imperial?.detail == "5.0 mi")
    }

    @Test("A long plan note is cut to its first sentence")
    func noteIsTrimmedToOneSentence() {
        let workout = ScheduledWorkout(
            scheduledDate: now,
            workoutType: .tempo,
            notes: "Hold marathon pace for the middle 5 km. Ease off if your heart rate drifts."
        )

        #expect(WidgetSnapshotBuilder.note(for: workout) == "Hold marathon pace for the middle 5 km")
    }

    @Test("A blank note is nil rather than an empty string")
    func blankNoteIsNil() {
        let blank = ScheduledWorkout(scheduledDate: now, workoutType: .tempo, notes: "   ")
        let missing = ScheduledWorkout(scheduledDate: now, workoutType: .tempo)

        #expect(WidgetSnapshotBuilder.note(for: blank) == nil)
        #expect(WidgetSnapshotBuilder.note(for: missing) == nil)
    }

    // MARK: - Day labels

    /// The reason the label is a function of the render date rather than a stored string:
    /// the app is not running at midnight to rewrite the file it left on disk.
    @Test("Day labels resolve against the render date, not the write date")
    func dayLabelsFollowTheRenderDate() {
        let plan = makePlan(in: makeContext(), sessions: [Session(date: offset(1, from: now))])
        let card = WidgetSnapshotBuilder.nextWorkout(in: plan, unit: .metric, now: now, calendar: calendar)

        #expect(card?.dayLabel(asOf: now, calendar: calendar) == "Tomorrow")
        #expect(card?.dayLabel(asOf: offset(1, from: now), calendar: calendar) == "Today")
        #expect(card?.dayLabel(asOf: offset(2, from: now), calendar: calendar) == "Overdue")
    }

    @Test("Days beyond tomorrow read as a weekday, then as a date")
    func distantDayLabels() {
        let inThreeDays = WidgetRelativeDay.label(for: offset(3, from: now), asOf: now, calendar: calendar)
        let inThreeWeeks = WidgetRelativeDay.label(for: offset(21, from: now), asOf: now, calendar: calendar)

        // A weekday name carries no digits; a date does.
        #expect(inThreeDays.rangeOfCharacter(from: .decimalDigits) == nil)
        #expect(inThreeWeeks.rangeOfCharacter(from: .decimalDigits) != nil)
    }

    // MARK: - Weekly goal

    @Test("Weekly progress counts only this Monday-anchored week")
    func weeklyProgressUsesMondayWeeks() {
        let weekStart = startOfWeek(now)
        let runs = [
            run(on: weekStart.addingTimeInterval(3_600), meters: 6_000),
            run(on: now, meters: 4_000),
            run(on: offset(-1, from: weekStart), meters: 10_000)   // last week
        ]

        let weekly = WidgetSnapshotBuilder.weekly(
            runs: runs,
            goalMeters: 40_000,
            unit: .metric,
            now: now,
            calendar: calendar
        )

        #expect(weekly.completedText == "10.0 km")
        #expect(weekly.goalText == "40 km")
        #expect(weekly.runCount == 2)
        #expect(weekly.isMet == false)
        #expect(abs(weekly.fraction - 0.25) < 0.001)
    }

    @Test("A met goal says so instead of counting down past zero")
    func metGoalChangesTheStatusLine() {
        let weekly = WidgetSnapshotBuilder.weekly(
            runs: [run(on: now, meters: 45_000)],
            goalMeters: 40_000,
            unit: .metric,
            now: now,
            calendar: calendar
        )

        #expect(weekly.isMet)
        #expect(weekly.fraction == 1)
        #expect(weekly.statusText == "Weekly goal met")
    }

    /// A zero goal must not render as a ring that can only ever read empty.
    @Test("No goal set is its own state, not a zero-length goal")
    func noGoalIsItsOwnState() {
        let weekly = WidgetSnapshotBuilder.weekly(
            runs: [run(on: now)],
            goalMeters: 0,
            unit: .metric,
            now: now,
            calendar: calendar
        )

        #expect(weekly.hasGoal == false)
        #expect(weekly.fraction == 0)
        #expect(weekly.isMet == false)
    }

    // MARK: - Race countdown

    @Test("The race counts down from the render date")
    func raceCountsDownFromRenderDate() {
        let plan = makePlan(
            in: makeContext(),
            raceName: "Berlin Marathon",
            raceDate: offset(63, from: now)
        )

        let race = WidgetSnapshotBuilder.race(plan: plan, profile: nil, now: now, calendar: calendar)

        #expect(race?.name == "Berlin Marathon")
        #expect(race?.daysRemaining(asOf: now, calendar: calendar) == 63)
        // The same snapshot, read a week later, without the app having run in between.
        #expect(race?.daysRemaining(asOf: offset(7, from: now), calendar: calendar) == 56)
        #expect(race?.goalTimeText == "3:29:00")
    }

    @Test("Race day itself still counts; the day after does not")
    func raceDayBoundary() {
        let plan = makePlan(in: makeContext(), raceName: "Race", raceDate: now)

        let race = WidgetSnapshotBuilder.race(plan: plan, profile: nil, now: now, calendar: calendar)

        #expect(race?.daysRemaining(asOf: now, calendar: calendar) == 0)
        #expect(race?.isUpcoming(asOf: now, calendar: calendar) == true)
        #expect(race?.isUpcoming(asOf: offset(1, from: now), calendar: calendar) == false)
    }

    @Test("A race already in the past is left out of the snapshot")
    func pastRaceIsOmitted() {
        let plan = makePlan(in: makeContext(), raceName: "Last Year", raceDate: offset(-2, from: now))

        #expect(WidgetSnapshotBuilder.race(plan: plan, profile: nil, now: now, calendar: calendar) == nil)
    }

    /// The two can legitimately disagree — a plan keeps the race it was built for while
    /// the profile moves on — and the countdown belongs to the plan being followed.
    @Test("The plan's race wins over the profile's")
    func planRaceBeatsProfileRace() {
        let profile = UserProfile(
            name: "Sam",
            goalRace: .fiveK,
            goalFinishTime: 1_500,
            raceName: "Parkrun",
            raceDate: offset(10, from: now),
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )
        let plan = makePlan(
            in: makeContext(),
            raceName: "Berlin Marathon",
            raceDate: offset(63, from: now)
        )

        let race = WidgetSnapshotBuilder.race(plan: plan, profile: profile, now: now, calendar: calendar)

        #expect(race?.name == "Berlin Marathon")
        #expect(race?.daysRemaining(asOf: now, calendar: calendar) == 63)
    }

    @Test("With no plan, the profile's race still counts down")
    func profileRaceIsUsedWithoutAPlan() {
        let profile = UserProfile(
            name: "Sam",
            goalRace: .halfMarathon,
            goalFinishTime: 5_400,
            raceName: "Great North Run",
            raceDate: offset(30, from: now),
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )

        let race = WidgetSnapshotBuilder.race(plan: nil, profile: profile, now: now, calendar: calendar)

        #expect(race?.name == "Great North Run")
        #expect(race?.goalTimeText == "1:30:00")
        #expect(race?.phaseLabel == nil)
    }

    @Test("An unnamed race falls back to the race type rather than going blank")
    func unnamedRaceFallsBackToItsType() {
        let plan = makePlan(in: makeContext(), raceName: nil, raceDate: offset(30, from: now))

        let race = WidgetSnapshotBuilder.race(plan: plan, profile: nil, now: now, calendar: calendar)

        #expect(race?.name == RaceType.marathon.localizedName)
    }

    @Test("The phase label names the week the plan is actually in")
    func phaseLabelReadsTheCurrentWeek() {
        let plan = makePlan(
            in: makeContext(),
            sessions: [Session(date: now)],
            phase: .peak,
            weekNumber: 12
        )

        let label = WidgetSnapshotBuilder.phaseLabel(for: plan, now: now, calendar: calendar)

        #expect(label?.hasPrefix(TrainingPhase.peak.localizedName) == true)
        #expect(label?.contains("12") == true)
    }

    @Test("A date outside every week of the plan has no phase")
    func phaseLabelIsNilOutsideThePlan() {
        let plan = makePlan(in: makeContext(), sessions: [Session(date: now)])

        #expect(WidgetSnapshotBuilder.phaseLabel(for: plan, now: offset(40, from: now), calendar: calendar) == nil)
    }

    // MARK: - Whole snapshot

    @Test("The assembled snapshot carries every section the widgets read")
    func snapshotAssemblesEverySection() {
        let plan = makePlan(
            in: makeContext(),
            sessions: [Session(date: now, type: .tempo)],
            raceName: "Berlin Marathon",
            raceDate: offset(63, from: now)
        )
        let runs = [run(on: now, meters: 10_000), run(on: offset(-1, from: now), meters: 8_000)]

        let snapshot = WidgetSnapshotBuilder.snapshot(
            plan: plan,
            runs: runs,
            profile: nil,
            weeklyGoalMeters: 40_000,
            unit: .metric,
            now: now,
            calendar: calendar
        )

        #expect(snapshot.nextWorkout?.title == WorkoutType.tempo.localizedName)
        #expect(snapshot.weekly.completedText == "18.0 km")
        #expect(snapshot.streak.current == 2)
        #expect(snapshot.streak.isActiveToday)
        #expect(snapshot.race?.name == "Berlin Marathon")
        #expect(snapshot.generatedAt == now)
        #expect(snapshot.isStale(asOf: now) == false)
    }

    /// A widget is a glance, and a stale week's mileage read at a glance is simply a wrong
    /// number — so past the window the extension shows the empty card instead.
    @Test("A snapshot past the staleness window reports itself stale")
    func staleSnapshotIsFlagged() {
        let snapshot = WidgetSnapshot.sample(now: now)

        #expect(snapshot.isStale(asOf: offset(4, from: now)) == false)
        #expect(snapshot.isStale(asOf: offset(9, from: now)))
    }

    @Test("With no plan and no runs the snapshot is empty rather than wrong")
    func emptySnapshotForANewInstall() {
        let snapshot = WidgetSnapshotBuilder.snapshot(
            plan: nil,
            runs: [],
            profile: nil,
            weeklyGoalMeters: 40_000,
            unit: .metric,
            now: now,
            calendar: calendar
        )

        #expect(snapshot.nextWorkout == nil)
        #expect(snapshot.race == nil)
        #expect(snapshot.streak.current == 0)
        #expect(snapshot.weekly.completedText == "0.0 km")
    }
}
