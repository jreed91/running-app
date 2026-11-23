import Foundation
import Testing
@testable import Stride

/// The rules for "not feeling 100%" and holiday mode (`TrainingBreakPlanner`), the numbers
/// behind them (`TrainingBreakPolicy`) and the record kept on the device
/// (`TrainingBreakStore`).
struct TrainingBreakPlannerTests {

    private let calendar = Calendar.current

    /// A fixed mid-morning Monday, through `Calendar.current` so "the same day" holds in
    /// whatever timezone the test runs in.
    private let monday = Calendar.current.date(
        from: DateComponents(year: 2027, month: 3, day: 15, hour: 9)
    ) ?? .now

    private func day(_ offset: Int) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: monday) ?? monday)
    }

    private typealias Session = PlanChangePlanner.Session

    /// Three weeks of a typical plan from this Monday: Tue intervals, Wed easy 6 km,
    /// Thu tempo 8 km, Fri strength, Sat long run (16, 17, 18 km), Sun rest.
    private func threeWeeks(raceOn raceOffset: Int? = nil, prescribesByTime: Bool = false) -> PlanChangePlanner.Plan {
        var sessions: [Session] = []
        for week in 0..<3 {
            let base = week * 7
            sessions += [
                Session(date: day(base + 1), type: .interval),
                Session(date: day(base + 2), type: .easy, targetDistanceMeters: 6_000),
                Session(date: day(base + 3), type: .tempo, targetDistanceMeters: 8_000),
                Session(date: day(base + 4), type: .strength),
                Session(date: day(base + 5), type: .longRun, targetDistanceMeters: Double(16 + week) * 1_000),
                Session(date: day(base + 6), type: .rest),
            ]
        }
        if let raceOffset {
            sessions.append(Session(date: day(raceOffset), type: .race, targetDistanceMeters: 21_097))
        }
        return PlanChangePlanner.Plan(
            sessions: sessions,
            startDate: day(-14),
            endDate: day(raceOffset ?? 40),
            raceDate: raceOffset.map(day),
            prescribesByTime: prescribesByTime
        )
    }

    private func propose(
        _ reason: TrainingBreak.Reason,
        _ mode: TrainingBreak.Mode,
        start: Int = 0,
        days: Int,
        in plan: PlanChangePlanner.Plan?,
        now: Date? = nil
    ) -> Result<TrainingBreakPlanner.Proposal, TrainingBreakPlanner.Refusal> {
        TrainingBreakPlanner.propose(
            TrainingBreakRequest(reason: reason, mode: mode, startDate: day(start), days: days),
            in: plan,
            now: now ?? monday,
            calendar: calendar
        )
    }

    private func proposal(
        _ reason: TrainingBreak.Reason,
        _ mode: TrainingBreak.Mode,
        start: Int = 0,
        days: Int,
        in plan: PlanChangePlanner.Plan
    ) throws -> TrainingBreakPlanner.Proposal {
        try propose(reason, mode, start: start, days: days, in: plan).get()
    }

    private func edit(on offset: Int, in proposal: TrainingBreakPlanner.Proposal) -> TrainingBreakPlanner.Edit? {
        proposal.edits.first { calendar.isDate($0.date, inSameDayAs: day(offset)) }
    }

    // MARK: Pause

    @Test("Ill and paused: every run and the strength session become rest days")
    func illPause() throws {
        let plan = threeWeeks()
        let result = try proposal(.ill, .pause, days: 5, in: plan)

        #expect(edit(on: 1, in: result)?.outcome == .rest)
        #expect(edit(on: 2, in: result)?.outcome == .rest)
        #expect(edit(on: 3, in: result)?.outcome == .rest)
        #expect(edit(on: 4, in: result)?.outcome == .rest, "Strength rests too when ill")
        #expect(edit(on: 4, in: result)?.fromType == .strength)
        #expect(result.edits.filter { $0.stage == .onBreak }.count == 4)
        #expect(result.endDate == day(4))
    }

    @Test("Injured and paused: strength and cross-training stay, the runs go")
    func injuredPauseKeepsStrength() throws {
        let result = try proposal(.injured, .pause, days: 5, in: threeWeeks())
        #expect(edit(on: 4, in: result) == nil)
        #expect(edit(on: 3, in: result)?.outcome == .rest)
    }

    @Test("A rest day and a completed run are left alone")
    func restAndCompletedUntouched() throws {
        var plan = threeWeeks()
        let done = Session(date: day(0), type: .easy, isCompleted: true, targetDistanceMeters: 5_000)
        plan = PlanChangePlanner.Plan(
            sessions: plan.sessions + [done],
            startDate: plan.startDate,
            endDate: plan.endDate
        )
        let result = try proposal(.ill, .pause, days: 7, in: plan)
        #expect(!result.edits.contains { $0.sessionID == done.id })
        #expect(edit(on: 6, in: result) == nil, "Sunday is already a rest day")
    }

    // MARK: Ease off

    @Test("Travelling and easing off: every run becomes an easy run at 70%")
    func travelEaseOff() throws {
        let result = try proposal(.travelling, .easeOff, days: 6, in: threeWeeks())

        #expect(edit(on: 3, in: result)?.outcome == .run(.easy, distanceMeters: 5_600), "Tempo 8 km")
        #expect(edit(on: 5, in: result)?.outcome == .run(.easy, distanceMeters: 11_200), "Long run 16 km")
        #expect(edit(on: 2, in: result)?.outcome == .run(.easy, distanceMeters: 4_200), "Easy 6 km")
        // Intervals carry no distance: they take the plan's usual easy run, 6 km.
        #expect(edit(on: 1, in: result)?.outcome == .run(.easy, distanceMeters: 4_200))
        #expect(edit(on: 4, in: result) == nil, "Easing off leaves strength alone")
    }

    @Test("An eased run is never under 2 km, nor longer than it was")
    func easeOffFloor() throws {
        let short = Session(date: day(1), type: .easy, targetDistanceMeters: 3_000)
        let tiny = Session(date: day(2), type: .easy, targetDistanceMeters: 1_600)
        let plan = PlanChangePlanner.Plan(sessions: [short, tiny], startDate: day(-7), endDate: day(30))
        let result = try proposal(.ill, .easeOff, days: 3, in: plan)

        #expect(edit(on: 1, in: result)?.outcome == .run(.easy, distanceMeters: 2_000))
        #expect(edit(on: 2, in: result)?.outcome == .run(.easy, distanceMeters: 1_600))
    }

    @Test("Easing off needs a pace-based plan; a Start Running plan can still pause")
    func timePlans() throws {
        let plan = threeWeeks(prescribesByTime: true)
        #expect(propose(.ill, .easeOff, days: 3, in: plan) == .failure(.easeOffNeedsPacePlan))

        let paused = try proposal(.ill, .pause, days: 10, in: plan)
        #expect(paused.ramp == nil, "No ramp on a plan prescribed by time")
        #expect(paused.rampEndDate == nil)
        #expect(paused.edits.allSatisfy { $0.stage == .onBreak })
    }

    // MARK: Easing back

    @Test("Two days off: straight back to the plan")
    func shortBreakNoRamp() throws {
        let result = try proposal(.ill, .pause, days: 2, in: threeWeeks())
        #expect(result.ramp == nil)
        #expect(result.edits.allSatisfy { $0.stage == .onBreak })
    }

    @Test("Five days ill: a week easing back, easy first, then the quality returns shorter")
    func weekRamp() throws {
        // Mon–Fri off; the ramp is Sat (day 5) to Fri (day 11).
        let result = try proposal(.ill, .pause, days: 5, in: threeWeeks())
        #expect(result.ramp?.days == 7)
        #expect(result.rampEndDate == day(11))

        // First half (Sat–Tue): long run 16 km at 70%, intervals turned easy.
        #expect(edit(on: 5, in: result)?.outcome == .run(.longRun, distanceMeters: 11_200))
        #expect(edit(on: 5, in: result)?.stage == .easingBack)
        #expect(edit(on: 8, in: result)?.outcome == .run(.easy, distanceMeters: 4_200))
        // Second half (Wed–Fri): easy 6 km at 85%, tempo kept as a tempo at 85%.
        #expect(edit(on: 9, in: result)?.outcome == .run(.easy, distanceMeters: 5_100))
        #expect(edit(on: 10, in: result)?.outcome == .run(.tempo, distanceMeters: 6_800))
        // Strength is not part of the ramp, and nothing after it changes.
        #expect(edit(on: 11, in: result) == nil)
        #expect(edit(on: 12, in: result) == nil)
    }

    @Test("After an injury, tempo and intervals stay easy for the whole ramp")
    func injuredRampEasyOnly() throws {
        let result = try proposal(.injured, .pause, days: 5, in: threeWeeks())
        #expect(edit(on: 10, in: result)?.outcome == .run(.easy, distanceMeters: 6_800))
    }

    @Test("Easing off counts as half its length: six easy days need no ramp, eight need a week")
    func easeOffRampLength() throws {
        #expect(TrainingBreakPolicy.ramp(after: 4, reason: .travelling, mode: .easeOff) == nil)
        #expect(TrainingBreakPolicy.ramp(after: 6, reason: .travelling, mode: .easeOff)?.days == 7)
        #expect(TrainingBreakPolicy.ramp(after: 10, reason: .ill, mode: .pause)?.days == 14)
        #expect(TrainingBreakPolicy.ramp(after: 20, reason: .ill, mode: .pause)?.firstHalfFactor == 0.5)
    }

    @Test("A long pause suggests rebuilding the plan")
    func longPauseSuggestsRebuild() throws {
        let result = try proposal(.injured, .pause, days: 16, in: threeWeeks())
        #expect(result.suggestsRebuild)
        #expect(try !proposal(.injured, .pause, days: 10, in: threeWeeks()).suggestsRebuild)
    }

    // MARK: Race

    @Test("A break over race day is refused")
    func raceInBreak() {
        let plan = threeWeeks(raceOn: 9)
        #expect(propose(.travelling, .pause, start: 7, days: 4, in: plan) == .failure(.raceDuringBreak(day(9))))
    }

    @Test("The ramp stops the day before the race, and never touches it")
    func rampStopsBeforeRace() throws {
        let plan = threeWeeks(raceOn: 11)
        let result = try proposal(.ill, .pause, days: 5, in: plan)
        #expect(result.rampEndDate == day(10))
        #expect(!result.edits.contains { $0.fromType == .race })
        #expect(result.edits.allSatisfy { $0.date < day(11) })
    }

    // MARK: Refusals

    @Test("Dates and lengths the plan won't take")
    func refusals() {
        let plan = threeWeeks()
        #expect(propose(.ill, .pause, start: -1, days: 3, in: plan) == .failure(.startInPast))
        #expect(propose(.travelling, .pause, start: 22, days: 3, in: plan) == .failure(.startTooFarAhead))
        #expect(propose(.ill, .pause, days: 0, in: plan) == .failure(.lengthOutOfRange))
        #expect(propose(.ill, .pause, days: 29, in: plan) == .failure(.lengthOutOfRange))
        #expect(propose(.ill, .pause, days: 3, in: nil) == .failure(.noPlan))
        // Sunday is already a rest day and the break is too short for a ramp.
        #expect(propose(.ill, .pause, start: 6, days: 1, in: plan) == .failure(.nothingToChange))
    }

    @Test("A break can start weeks ahead, for a booked holiday")
    func breakAhead() throws {
        let result = try proposal(.travelling, .pause, start: 14, days: 7, in: threeWeeks())
        #expect(result.startDate == day(14))
        #expect(edit(on: 15, in: result)?.outcome == .rest)
        #expect(edit(on: 8, in: result) == nil)
    }

    // MARK: Early return

    @Test("Back early after four days off: a week's ramp from today")
    func earlyReturn() throws {
        let plan = threeWeeks()
        let today = calendar.date(byAdding: .day, value: 4, to: monday) ?? monday
        let ramp = try #require(TrainingBreakPlanner.rampForEarlyReturn(
            reason: .ill, mode: .pause, breakStart: day(0), in: plan, now: today, calendar: calendar
        ))
        #expect(ramp.ramp.days == 7)
        #expect(ramp.lastDay == day(10))
        #expect(ramp.edits.first?.date == day(5), "Friday's strength isn't ramped; Saturday's long run is first")
    }

    @Test("Back the day after starting: nothing to ease back from")
    func earlyReturnTooSoon() {
        let today = calendar.date(byAdding: .day, value: 1, to: monday) ?? monday
        #expect(TrainingBreakPlanner.rampForEarlyReturn(
            reason: .ill, mode: .pause, breakStart: day(0), in: threeWeeks(), now: today, calendar: calendar
        ) == nil)
    }

    // MARK: Phase and store

    private func record(start: Int, end: Int, rampEnd: Int?, planID: UUID = UUID(), sessionID: UUID = UUID()) -> TrainingBreak {
        TrainingBreak(
            planID: planID,
            reason: .ill,
            mode: .pause,
            startDate: day(start),
            endDate: day(end),
            rampEndDate: rampEnd.map(day),
            createdAt: monday,
            changes: [
                .init(
                    sessionID: sessionID,
                    original: .init(
                        workoutTypeRaw: WorkoutType.tempo.rawValue,
                        targetDistanceMeters: 8_000,
                        targetPaceLowerBound: 270,
                        targetPaceUpperBound: 280,
                        notes: nil,
                        intervalsData: nil,
                        structureData: nil,
                        strengthData: nil
                    ),
                    appliedTypeRaw: WorkoutType.rest.rawValue,
                    appliedDistanceMeters: nil
                )
            ]
        )
    }

    @Test("A break's phase on each day")
    func phases() {
        let trainingBreak = record(start: 2, end: 4, rampEnd: 11)
        #expect(trainingBreak.phase(on: day(1), calendar: calendar) == .upcoming)
        #expect(trainingBreak.phase(on: day(2), calendar: calendar) == .onBreak)
        #expect(trainingBreak.phase(on: day(4), calendar: calendar) == .onBreak)
        #expect(trainingBreak.phase(on: day(5), calendar: calendar) == .easingBack)
        #expect(trainingBreak.phase(on: day(11), calendar: calendar) == .easingBack)
        #expect(trainingBreak.phase(on: day(12), calendar: calendar) == .finished)
        #expect(trainingBreak.length(calendar: calendar) == 3)
    }

    @Test("The store keeps live breaks, protects their sessions, and drops finished ones")
    func store() throws {
        let defaults = try #require(UserDefaults(suiteName: "TrainingBreakStoreTests-\(UUID())"))
        let planID = UUID()
        let sessionID = UUID()
        let live = record(start: 0, end: 3, rampEnd: 10, planID: planID, sessionID: sessionID)
        TrainingBreakStore.save(live, now: monday, in: defaults)

        #expect(TrainingBreakStore.current(forPlan: planID, now: monday, calendar: calendar, in: defaults) == live)
        #expect(TrainingBreakStore.current(forPlan: UUID(), now: monday, calendar: calendar, in: defaults) == nil)
        #expect(TrainingBreakStore.protectedIDs(now: monday, in: defaults) == [sessionID])

        let later = day(11)
        #expect(TrainingBreakStore.current(forPlan: planID, now: later, calendar: calendar, in: defaults) == nil)
        #expect(TrainingBreakStore.protectedIDs(now: later, in: defaults).isEmpty)

        TrainingBreakStore.remove(id: live.id, in: defaults)
        #expect(TrainingBreakStore.current(forPlan: planID, now: monday, calendar: calendar, in: defaults) == nil)
    }

    // MARK: Coach

    @Test("The coach is told about the break in each phase, and nothing once it's over")
    func coachNote() {
        let trainingBreak = record(start: 2, end: 4, rampEnd: 11)
        #expect(trainingBreak.coachNote(on: day(0), calendar: calendar)?.contains("break booked") == true)
        let during = trainingBreak.coachNote(on: day(3), calendar: calendar) ?? ""
        #expect(during.contains("ill"))
        #expect(during.contains("Don't suggest tempo"))
        #expect(during.contains("I'm back"))
        #expect(trainingBreak.coachNote(on: day(6), calendar: calendar)?.contains("easing back in") == true)
        #expect(trainingBreak.coachNote(on: day(12), calendar: calendar) == nil)
    }

    @Test("The coach chat can rest a day or keep it easy during a break, never add or harden one")
    func coachChangesDuringBreak() {
        let tempoID = UUID()
        let easyID = UUID()
        let plan = PlanChangePlanner.Plan(
            sessions: [
                Session(id: tempoID, date: day(3), type: .tempo, targetDistanceMeters: 6_000),
                Session(id: easyID, date: day(1), type: .easy, targetDistanceMeters: 3_000),
            ],
            startDate: day(-7),
            endDate: day(40),
            breakDays: day(0)...day(4)
        )
        func weekday(_ offset: Int) -> PlanChangeRequest.Day {
            .weekday(calendar.component(.weekday, from: day(offset)))
        }
        func planned(_ request: PlanChangeRequest) -> Result<PlanChangePlanner.Change, PlanChangePlanner.Refusal> {
            PlanChangePlanner.plan(request, in: plan, now: monday, calendar: calendar)
        }

        #expect(planned(.init(action: .add, day: weekday(2), type: .easy)) == .failure(.duringTrainingBreak(day(2))))
        #expect(planned(.init(action: .changeType, day: weekday(1), type: .interval)) == .failure(.duringTrainingBreak(day(1))))
        #expect(planned(.init(action: .changeType, day: weekday(1), type: .easy, distanceMeters: 8_000))
                == .failure(.duringTrainingBreak(day(1))))
        #expect(planned(.init(action: .makeRest, day: weekday(1))) == .success(.makeRest(sessionID: easyID, date: day(1), type: .easy)))
        if case .success(.changeType(_, _, .tempo, .easy, _)) = planned(.init(action: .changeType, day: weekday(3), type: .easy)) {
        } else {
            Issue.record("Turning a tempo easy during a break is fine")
        }
        // After the break, the planner's own rules apply again.
        if case .failure(.duringTrainingBreak) = planned(.init(action: .add, day: weekday(5), type: .easy)) {
            Issue.record("Day 5 is after the break")
        }
    }
}
