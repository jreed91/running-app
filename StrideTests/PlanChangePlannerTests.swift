import Foundation
import SwiftData
import Testing
@testable import Stride

/// The rules for a plan change the runner asks the coach for (`PlanChangePlanner`), and
/// the write that follows their confirmation (`PlanChangeApplier`).
@MainActor
struct PlanChangePlannerTests {

    private let calendar = Calendar.current

    /// A fixed mid-morning Monday, through `Calendar.current` so "the same day" holds in
    /// whatever timezone the test runs in.
    private let monday = Calendar.current.date(
        from: DateComponents(year: 2027, month: 3, day: 15, hour: 9)
    ) ?? .now

    private func day(_ offset: Int) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: monday) ?? monday)
    }

    private func weekday(_ offset: Int) -> PlanChangeRequest.Day {
        .weekday(calendar.component(.weekday, from: day(offset)))
    }

    /// Jacob's week: one long run on Saturday, nothing else.
    private func oneRunWeek(longRunKm: Double = 13) -> PlanChangePlanner.Plan {
        PlanChangePlanner.Plan(
            sessions: [.init(date: day(5), type: .longRun, targetDistanceMeters: longRunKm * 1_000)],
            startDate: day(-7),
            endDate: day(60)
        )
    }

    private func plan(_ request: PlanChangeRequest, in plan: PlanChangePlanner.Plan?) -> Result<PlanChangePlanner.Change, PlanChangePlanner.Refusal> {
        PlanChangePlanner.plan(request, in: plan, now: monday, calendar: calendar)
    }

    // MARK: Add

    @Test("An interval run with no day named lands midweek, away from the long run")
    func addIntervalsBestDay() throws {
        let result = plan(.init(action: .add, day: .best, type: .interval), in: oneRunWeek())
        guard case .success(.add(let date, let type, let distance, let restID)) = result else {
            Issue.record("Expected an add, got \(result)")
            return
        }
        #expect(type == .interval)
        // Saturday's long run is day 5; the furthest free day from it, never today, is
        // Tuesday (day 1), four days away.
        #expect(date == day(1))
        #expect(distance == nil, "Intervals carry their distance in the reps")
        #expect(restID == nil)
    }

    @Test("A named weekday resolves to the next one from today, today included")
    func namedWeekday() throws {
        let result = plan(.init(action: .add, day: weekday(2), type: .easy), in: oneRunWeek())
        guard case .success(.add(let date, _, _, _)) = result else {
            Issue.record("Expected an add, got \(result)")
            return
        }
        #expect(date == day(2))

        let today = plan(.init(action: .add, day: weekday(0), type: .easy), in: oneRunWeek())
        guard case .success(.add(let todayDate, _, _, _)) = today else {
            Issue.record("Expected an add, got \(today)")
            return
        }
        #expect(todayDate == day(0))
    }

    @Test("A day that already has a run is refused, so the coach can offer to change it")
    func addOnRunDayRefused() {
        let result = plan(.init(action: .add, day: weekday(5), type: .easy), in: oneRunWeek())
        #expect(result == .failure(.dayHasRun(day(5), .longRun)))
    }

    @Test("A hard session the day before or after the long run is refused; an easy one is fine")
    func hardNextToLongRun() {
        let friday = plan(.init(action: .add, day: weekday(4), type: .interval), in: oneRunWeek())
        guard case .failure(.nextToHardDay(let date, let neighbour, _)) = friday else {
            Issue.record("Expected a spacing refusal, got \(friday)")
            return
        }
        #expect(date == day(4))
        #expect(neighbour == .longRun)

        let easyFriday = plan(.init(action: .add, day: weekday(4), type: .easy), in: oneRunWeek())
        guard case .success = easyFriday else {
            Issue.record("An easy run beside the long run should be allowed, got \(easyFriday)")
            return
        }
    }

    @Test("No hard session in the two days before the race, and nothing on or after it")
    func raceSpacing() {
        let racePlan = PlanChangePlanner.Plan(
            sessions: [.init(date: day(4), type: .race, targetDistanceMeters: 10_000)],
            startDate: day(-30),
            endDate: day(4),
            raceDate: day(4)
        )
        let twoDaysOut = plan(.init(action: .add, day: weekday(2), type: .tempo), in: racePlan)
        #expect(twoDaysOut == .failure(.tooCloseToRace(day(2))))

        let afterRace = plan(.init(action: .add, day: weekday(5), type: .easy), in: racePlan)
        #expect(afterRace == .failure(.dayOutsideWindow(day(5))))

        let restRace = plan(.init(action: .makeRest, day: weekday(4)), in: racePlan)
        #expect(restRace == .failure(.sessionLocked(day(4), .race)))
    }

    @Test("A stored rest day is free, and the new run takes its row")
    func addReplacesRestRow() {
        let restID = UUID()
        let week = PlanChangePlanner.Plan(
            sessions: [
                .init(id: restID, date: day(2), type: .rest),
                .init(date: day(5), type: .longRun, targetDistanceMeters: 13_000),
            ],
            startDate: day(-7),
            endDate: day(60)
        )
        let result = plan(.init(action: .add, day: weekday(2), type: .tempo), in: week)
        guard case .success(.add(_, _, _, let replacing)) = result else {
            Issue.record("Expected an add, got \(result)")
            return
        }
        #expect(replacing == restID)
    }

    @Test("An added run is never longer than the long run near it")
    func addedDistanceCapped() {
        let result = plan(.init(action: .add, day: weekday(2), type: .easy, distanceMeters: 20_000), in: oneRunWeek(longRunKm: 13))
        guard case .success(.add(_, _, let distance, _)) = result else {
            Issue.record("Expected an add, got \(result)")
            return
        }
        #expect(distance == 13_000)
    }

    @Test("Strength, race and rest can't be added")
    func unsupportedTypes() {
        for type in [WorkoutType.race, .strength, .rest, .crossTraining] {
            #expect(plan(.init(action: .add, day: .best, type: type), in: oneRunWeek()) == .failure(.unsupportedType))
        }
        #expect(plan(.init(action: .add, day: .best), in: oneRunWeek()) == .failure(.unsupportedType))
    }

    @Test("Only the coming week can change")
    func outsideWindow() {
        let tomorrowPlanEnds = PlanChangePlanner.Plan(sessions: [], startDate: day(-30), endDate: day(1))
        let result = plan(.init(action: .add, day: weekday(3), type: .easy), in: tomorrowPlanEnds)
        #expect(result == .failure(.dayOutsideWindow(day(3))))
    }

    @Test("A time-prescribed plan and no plan are both refused")
    func planKinds() {
        let startRunning = PlanChangePlanner.Plan(sessions: [], startDate: day(-7), endDate: day(60), prescribesByTime: true)
        #expect(plan(.init(action: .add, day: .best, type: .easy), in: startRunning) == .failure(.planPrescribesByTime))
        #expect(plan(.init(action: .add, day: .best, type: .easy), in: nil) == .failure(.noPlan))
    }

    // MARK: Change type and rest

    @Test("Changing a run's type keeps its id and refuses the same type with no distance")
    func changeType() {
        let easyID = UUID()
        let week = PlanChangePlanner.Plan(
            sessions: [
                .init(id: easyID, date: day(2), type: .easy, targetDistanceMeters: 6_000),
                .init(date: day(5), type: .longRun, targetDistanceMeters: 13_000),
            ],
            startDate: day(-7),
            endDate: day(60)
        )
        let result = plan(.init(action: .changeType, day: weekday(2), type: .interval), in: week)
        #expect(result == .success(.changeType(sessionID: easyID, date: day(2), from: .easy, to: .interval, distanceMeters: nil)))

        let same = plan(.init(action: .changeType, day: weekday(2), type: .easy), in: week)
        #expect(same == .failure(.sameType(day(2), .easy)))
    }

    @Test("A long run can be shortened by asking for its distance")
    func shortenLongRun() {
        let longID = UUID()
        let week = PlanChangePlanner.Plan(
            sessions: [.init(id: longID, date: day(5), type: .longRun, targetDistanceMeters: 42_000)],
            startDate: day(-7),
            endDate: day(60)
        )
        let result = plan(.init(action: .changeType, day: weekday(5), type: .longRun, distanceMeters: 12_874), in: week)
        #expect(result == .success(.changeType(sessionID: longID, date: day(5), from: .longRun, to: .longRun, distanceMeters: 12_874)))
    }

    @Test("A session changing to a hard type isn't its own neighbour")
    func changeIgnoresItself() {
        let tempoID = UUID()
        let week = PlanChangePlanner.Plan(
            sessions: [.init(id: tempoID, date: day(2), type: .tempo, targetDistanceMeters: 6_000)],
            startDate: day(-7),
            endDate: day(60)
        )
        let result = plan(.init(action: .changeType, day: weekday(2), type: .interval), in: week)
        guard case .success = result else {
            Issue.record("Expected the change, got \(result)")
            return
        }
    }

    @Test("Rest takes the named run; a completed one or an empty day is refused")
    func makeRest() {
        let runID = UUID()
        let doneID = UUID()
        let week = PlanChangePlanner.Plan(
            sessions: [
                .init(id: doneID, date: day(0), type: .easy, isCompleted: true, targetDistanceMeters: 5_000),
                .init(id: runID, date: day(3), type: .tempo, targetDistanceMeters: 6_000),
            ],
            startDate: day(-7),
            endDate: day(60)
        )
        #expect(plan(.init(action: .makeRest, day: weekday(3)), in: week) == .success(.makeRest(sessionID: runID, date: day(3), type: .tempo)))
        #expect(plan(.init(action: .makeRest, day: weekday(0)), in: week) == .failure(.sessionLocked(day(0), .easy)))
        #expect(plan(.init(action: .makeRest, day: weekday(1)), in: week) == .failure(.noSessionOnDay(day(1))))
        // No day named: the soonest open run.
        #expect(plan(.init(action: .makeRest, day: .best), in: week) == .success(.makeRest(sessionID: runID, date: day(3), type: .tempo)))
    }

    // MARK: Applier

    private func makeStoredPlan(in context: ModelContext) throws -> (TrainingPlan, ScheduledWorkout) {
        let plan = TrainingPlan(targetRace: .tenK, goalTimeSeconds: 3_000, startDate: day(-7), endDate: day(20))
        plan.isActive = true
        context.insert(plan)
        for index in 0..<4 {
            let week = TrainingWeek(weekNumber: index + 1, startDate: day(-7 + index * 7), phase: .base, targetDistanceKm: 20)
            context.insert(week)
            week.plan = plan
        }
        let thisWeek = try #require(plan.weeks?.first { $0.weekNumber == 2 })
        let longRun = ScheduledWorkout(scheduledDate: day(5), workoutType: .longRun, targetDistanceMeters: 13_000)
        context.insert(longRun)
        longRun.week = thisWeek
        try context.save()
        return (plan, longRun)
    }

    private var profile: UserProfile {
        UserProfile(
            name: "Runner",
            goalRace: .tenK,
            goalFinishTime: 3_000,
            weeklyRunDays: 1,
            fitnessLevel: .beginner,
            currentEstimated5KTimeSeconds: 1_800
        )
    }

    @Test("Applying an add inserts one built interval session into the right week")
    func applyAdd() throws {
        let context = TestStore.makeContext()
        let (plan, _) = try makeStoredPlan(in: context)

        let change = PlanChangePlanner.Change.add(date: day(1), type: .interval, distanceMeters: nil, replacingRestID: nil)
        let added = try PlanChangeApplier.apply(change, to: plan, context: context, history: [], profile: profile, unitPreference: .imperial)

        #expect(added.workoutType == .interval)
        #expect(calendar.isDate(added.scheduledDate, inSameDayAs: day(1)))
        #expect(added.week?.weekNumber == 2)
        #expect(!added.intervals.isEmpty || added.workoutStructure != nil, "Built from the plan's own rules, with reps")
        #expect(added.targetPaceLowerBound != nil)

        let all = try context.fetch(FetchDescriptor<ScheduledWorkout>())
        #expect(all.count == 2)
    }

    @Test("Applying to a day that gained a run since the proposal throws and writes nothing")
    func applyStale() throws {
        let context = TestStore.makeContext()
        let (plan, _) = try makeStoredPlan(in: context)
        let change = PlanChangePlanner.Change.add(date: day(5), type: .easy, distanceMeters: 5_000, replacingRestID: nil)
        #expect(throws: PlanChangeApplier.ApplyError.planChanged) {
            try PlanChangeApplier.apply(change, to: plan, context: context, history: [], profile: profile, unitPreference: .metric)
        }
        #expect(try context.fetch(FetchDescriptor<ScheduledWorkout>()).count == 1)
    }

    @Test("Make rest keeps the row as a rest day with no targets")
    func applyRest() throws {
        let context = TestStore.makeContext()
        let (plan, longRun) = try makeStoredPlan(in: context)
        let change = PlanChangePlanner.Change.makeRest(sessionID: longRun.id, date: longRun.scheduledDate, type: .longRun)
        let rested = try PlanChangeApplier.apply(change, to: plan, context: context, history: [], profile: profile, unitPreference: .metric)

        #expect(rested.id == longRun.id)
        #expect(rested.workoutType == .rest)
        #expect(rested.targetDistanceMeters == nil)
        #expect(rested.targetPaceLowerBound == nil)
        #expect(rested.workoutStructure == nil)
    }

    @Test("Changing a long run's distance rebuilds it at that distance")
    func applyShorterLongRun() throws {
        let context = TestStore.makeContext()
        let (plan, longRun) = try makeStoredPlan(in: context)
        let change = PlanChangePlanner.Change.changeType(
            sessionID: longRun.id, date: longRun.scheduledDate, from: .longRun, to: .longRun, distanceMeters: 8_000
        )
        let changed = try PlanChangeApplier.apply(change, to: plan, context: context, history: [], profile: profile, unitPreference: .metric)
        #expect(changed.id == longRun.id)
        #expect(changed.workoutType == .longRun)
        #expect(changed.targetDistanceMeters == 8_000)
    }
}
