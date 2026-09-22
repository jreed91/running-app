import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers `RaceDayPlan`, the state the race-day hub is drawn from.
///
/// Three things here are decisions rather than arithmetic, and they are what the tests
/// are pinned on: the goal ladder is built *down* from the time the runner set, the split
/// table closes on the race distance rather than on a whole marker, and a run on race
/// morning only counts as the race if it covers most of the race distance.
@MainActor
struct RaceDayPlanTests {

    /// Fixed anchor: 2023-11-14 22:13:20 UTC, a Tuesday. The same anchor
    /// `CoachSituationTests` uses.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var calendar: Calendar { .current }

    private func day(_ offset: Int) -> Date {
        now.addingTimeInterval(Double(offset) * 86_400)
    }

    // MARK: Fixtures

    private func makeProfile(
        in context: ModelContext,
        race: RaceType = .marathon,
        raceIn days: Int? = 12,
        goalSeconds: TimeInterval = 12_600,
        raceName: String? = "Dublin Marathon",
        estimated5K: Double? = nil
    ) -> UserProfile {
        let profile = UserProfile(
            name: "Sam",
            goalRace: race,
            goalFinishTime: goalSeconds,
            raceName: raceName,
            raceDate: days.map { day($0) },
            weeklyRunDays: 4,
            fitnessLevel: .intermediate,
            currentEstimated5KTimeSeconds: estimated5K
        )
        context.insert(profile)
        return profile
    }

    private func makePlan(
        in context: ModelContext,
        race: RaceType = .marathon,
        raceIn days: Int? = 12,
        goalSeconds: TimeInterval = 12_600,
        raceName: String? = "Dublin Marathon",
        kind: PlanKind = .standard
    ) -> TrainingPlan {
        let plan = TrainingPlan(
            targetRace: race,
            goalTimeSeconds: goalSeconds,
            raceName: raceName,
            raceDate: days.map { day($0) },
            startDate: day(-80),
            endDate: day(days ?? 0)
        )
        plan.planKind = kind
        context.insert(plan)
        return plan
    }

    /// Adds `count` weeks ending on the week that contains today, so `taperStatus` has a
    /// current week to find. Volumes ramp to `peakKm` and drop to `taperKm` in the last.
    @discardableResult
    private func addWeeks(
        to plan: TrainingPlan,
        in context: ModelContext,
        peakKm: Double = 70,
        thisWeekKm: Double = 42,
        phase: TrainingPhase = .taper
    ) -> [TrainingWeek] {
        let earlier = TrainingWeek(
            weekNumber: 1,
            startDate: day(-14),
            phase: .peak,
            targetDistanceKm: peakKm
        )
        let current = TrainingWeek(
            weekNumber: 2,
            startDate: day(-2),
            phase: phase,
            targetDistanceKm: thisWeekKm
        )
        for week in [earlier, current] {
            week.plan = plan
            context.insert(week)
        }
        plan.weeks = [earlier, current]
        return [earlier, current]
    }

    private func makeRun(
        in context: ModelContext,
        daysAgo: Int,
        distanceMeters: Double = 42_195,
        durationSeconds: Double = 12_500,
        type: WorkoutType = .race
    ) -> RunWorkout {
        let run = RunWorkout(
            date: day(-daysAgo),
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            workoutType: type
        )
        context.insert(run)
        return run
    }

    private func resolve(
        profile: UserProfile? = nil,
        plan: TrainingPlan? = nil,
        runs: [RunWorkout] = []
    ) -> RaceDayPlan? {
        RaceDayPlan.resolve(profile: profile, plan: plan, runs: runs, now: now, calendar: calendar)
    }

    // MARK: - Phase

    @Test("A race further out than race week is still building toward it")
    func buildingPhase() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceIn: 30)

        #expect(resolve(profile: profile)?.phase == .building(daysOut: 30))
    }

    @Test("A race inside the week is race week, and the last day before it is one day out")
    func raceWeekPhase() {
        let context = TestStore.makeContext()

        #expect(resolve(profile: makeProfile(in: context, raceIn: 7))?.phase == .raceWeek(daysOut: 7))
        #expect(resolve(profile: makeProfile(in: context, raceIn: 1))?.phase == .raceWeek(daysOut: 1))
        #expect(resolve(profile: makeProfile(in: context, raceIn: 8))?.phase == .building(daysOut: 8))
    }

    @Test("Race morning and the days after it are their own phases")
    func raceDayAndAfter() {
        let context = TestStore.makeContext()

        #expect(resolve(profile: makeProfile(in: context, raceIn: 0))?.phase == .raceDay)
        #expect(resolve(profile: makeProfile(in: context, raceIn: -2))?.phase == .finished(daysSince: 2))
    }

    @Test("No goal race means no hub at all")
    func noRace() {
        let context = TestStore.makeContext()

        #expect(resolve(profile: makeProfile(in: context, raceIn: nil)) == nil)
        #expect(resolve(profile: makeProfile(in: context, race: .maintainFitness)) == nil)
        #expect(resolve() == nil)
    }

    @Test("A pregnancy plan has no race to peak on, even with a date left on the profile")
    func pregnancyPlanHasNoRace() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceIn: 12)
        let plan = makePlan(in: context, race: .maintainFitness, raceIn: nil, goalSeconds: 0, kind: .pregnancy)

        #expect(resolve(profile: profile, plan: plan) == nil)
    }

    @Test("The plan's race wins over a stale one left on the profile")
    func planWinsOverProfile() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, race: .fiveK, raceIn: 40, goalSeconds: 1_500, raceName: "Parkrun")
        let plan = makePlan(in: context, race: .halfMarathon, raceIn: 9, goalSeconds: 6_300, raceName: "Cork Half")

        let resolved = resolve(profile: profile, plan: plan)
        #expect(resolved?.raceName == "Cork Half")
        #expect(resolved?.raceType == .halfMarathon)
        #expect(resolved?.phase == .building(daysOut: 9))
    }

    @Test("An unnamed race falls back to the race type's own name")
    func unnamedRace() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceName: "   ")

        #expect(resolve(profile: profile)?.raceName == RaceType.marathon.localizedName)
    }

    // MARK: - Goal ladder

    @Test("The goal the runner set is the A goal, and B and C are built down from it")
    func goalLadderIsBuiltDown() {
        let goals = RaceDayPlan.goals(forGoalSeconds: 12_600, distanceMeters: 42_195)

        #expect(goals.count == 3)
        #expect(goals.map(\.tier) == [.a, .b, .c])
        #expect(goals[0].finishSeconds == 12_600)
        #expect(abs(goals[1].finishSeconds - 12_978) < 0.5)      // +3 %
        #expect(abs(goals[2].finishSeconds - 13_482) < 0.5)      // +7 %
        // Every rung is slower than the one above it, which is the whole point of a ladder.
        #expect(goals[0].finishSeconds < goals[1].finishSeconds)
        #expect(goals[1].finishSeconds < goals[2].finishSeconds)
    }

    @Test("Each rung's pace is its own finish time over the race distance")
    func goalPacesMatchTheirFinishTimes() {
        let goals = RaceDayPlan.goals(forGoalSeconds: 12_600, distanceMeters: 42_195)

        for goal in goals {
            let implied = goal.paceSecondsPerKm * (42_195 / 1_000)
            #expect(abs(implied - goal.finishSeconds) < 0.001)
        }
    }

    @Test("No goal time means no ladder, and the countdown still stands")
    func noGoalTimeStillCountsDown() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, goalSeconds: 0)

        let resolved = resolve(profile: profile)
        #expect(resolved?.goals.isEmpty == true)
        #expect(resolved?.phase == .building(daysOut: 12))
    }

    // MARK: - Splits

    @Test("A metric marathon closes on the finish, not on the 42nd kilometre")
    func marathonSplitsMetric() {
        let splits = RaceDayPlan.splits(distanceMeters: 42_195, paceSecondsPerKm: 300, unit: .metric)

        #expect(splits.count == 43)
        #expect(splits[0].distanceMeters == 1_000)
        #expect(splits[0].elapsedSeconds == 300)
        let last = splits[splits.count - 1]
        #expect(last.isPartial)
        #expect(last.distanceMeters == 42_195)
        // The final row is the goal time itself — 42.195 km at 5:00/km.
        #expect(abs(last.elapsedSeconds - 12_658.5) < 0.001)
    }

    @Test("A distance that lands on a whole marker has no partial row")
    func exactDistanceHasNoPartial() {
        let splits = RaceDayPlan.splits(distanceMeters: 5_000, paceSecondsPerKm: 240, unit: .metric)

        #expect(splits.count == 5)
        #expect(!splits.contains(where: { $0.isPartial }))
        #expect(splits[4].elapsedSeconds == 1_200)
    }

    @Test("Imperial markers are miles, and a half marathon leaves one over")
    func halfMarathonSplitsImperial() {
        let splits = RaceDayPlan.splits(distanceMeters: 21_097.5, paceSecondsPerKm: 300, unit: .imperial)

        #expect(splits.count == 14)                       // 13 whole miles plus the finish
        #expect(abs(splits[0].distanceMeters - 1_609.344) < 0.001)
        #expect(splits[13].isPartial)
        #expect(splits[13].distanceMeters == 21_097.5)
    }

    @Test("A race shorter than one marker is a single finish row")
    func shorterThanOneMarker() {
        let splits = RaceDayPlan.splits(distanceMeters: 800, paceSecondsPerKm: 240, unit: .metric)

        #expect(splits.count == 1)
        #expect(splits[0].isPartial)
        #expect(abs(splits[0].elapsedSeconds - 192) < 0.001)
    }

    @Test("A degenerate pace or distance produces no table rather than a divide by zero")
    func degenerateSplits() {
        #expect(RaceDayPlan.splits(distanceMeters: 0, paceSecondsPerKm: 300, unit: .metric).isEmpty)
        #expect(RaceDayPlan.splits(distanceMeters: 5_000, paceSecondsPerKm: 0, unit: .metric).isEmpty)
    }

    // MARK: - Taper

    @Test("This week is reported against the plan's biggest week")
    func taperStatusReadsThisWeek() {
        let context = TestStore.makeContext()
        let plan = makePlan(in: context)
        addWeeks(to: plan, in: context, peakKm: 70, thisWeekKm: 42)

        let taper = resolve(profile: makeProfile(in: context), plan: plan)?.taper
        #expect(taper?.weekNumber == 2)
        #expect(taper?.phase == .taper)
        #expect(taper?.plannedKm == 42)
        #expect(taper?.peakKm == 70)
        #expect(abs((taper?.reductionFromPeak ?? 0) - 0.4) < 0.001)
    }

    @Test("A week at the peak is not a negative taper")
    func peakWeekReportsNoReduction() {
        let status = RaceTaperStatus(
            phase: .peak,
            weekNumber: 9,
            totalWeeks: 16,
            plannedKm: 70,
            peakKm: 70
        )
        #expect(status.reductionFromPeak == 0)
    }

    @Test("A plan with no week covering today reports no taper")
    func noCurrentWeekNoTaper() {
        let context = TestStore.makeContext()
        let plan = makePlan(in: context)

        #expect(resolve(profile: makeProfile(in: context), plan: plan)?.taper == nil)
    }

    // MARK: - Result

    @Test("The run linked to the plan's race day is the result")
    func linkedRaceRunIsTheResult() {
        let context = TestStore.makeContext()
        let plan = makePlan(in: context, raceIn: -1, goalSeconds: 12_600)
        let weeks = addWeeks(to: plan, in: context)
        let scheduled = ScheduledWorkout(
            scheduledDate: day(-1),
            workoutType: .race,
            targetDistanceMeters: 42_195
        )
        scheduled.week = weeks[1]
        context.insert(scheduled)
        weeks[1].workouts = [scheduled]

        let run = makeRun(in: context, daysAgo: 1, durationSeconds: 12_400)
        scheduled.completedWorkout = run

        let result = resolve(profile: makeProfile(in: context, raceIn: -1), plan: plan, runs: [run])?.result
        #expect(result?.finishSeconds == 12_400)
        #expect(result?.tierAchieved == .a)
        #expect(abs((result?.secondsInsideGoal ?? 0) - 200) < 0.001)
    }

    @Test("A race imported from Health is found by its date and distance")
    func unlinkedRaceRunIsFound() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceIn: -1)
        let run = makeRun(in: context, daysAgo: 1, durationSeconds: 13_000, type: .easy)

        let result = resolve(profile: profile, runs: [run])?.result
        #expect(result?.finishSeconds == 13_000)
        // 13 000 s is outside the A goal (12 600) but inside the C goal (13 482).
        #expect(result?.tierAchieved == .c)
        #expect((result?.secondsInsideGoal ?? 0) < 0)
    }

    @Test("A shakeout on race morning is not the race")
    func shakeoutIsNotTheResult() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceIn: -1)
        let shakeout = makeRun(in: context, daysAgo: 1, distanceMeters: 3_000, durationSeconds: 1_080, type: .easy)

        #expect(resolve(profile: profile, runs: [shakeout])?.result == nil)
    }

    @Test("A race still ahead has no result")
    func noResultBeforeTheRace() {
        let context = TestStore.makeContext()

        #expect(resolve(profile: makeProfile(in: context, raceIn: 3))?.result == nil)
    }

    @Test("A finish outside every rung is still reported, with the gap")
    func missedEveryRung() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceIn: -1)
        let run = makeRun(in: context, daysAgo: 1, durationSeconds: 14_400, type: .race)

        let result = resolve(profile: profile, runs: [run])?.result
        #expect(result?.tierAchieved == nil)
        #expect(abs((result?.secondsInsideGoal ?? 0) + 1_800) < 0.001)
    }

    // MARK: - Prediction

    @Test("The predicted finish comes from quality efforts, not from easy runs")
    func predictionUsesQualityEfforts() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, race: .fiveK, raceIn: 10, goalSeconds: 1_200)
        // A 20-minute 5 K tempo — a real fitness sample.
        let quality = makeRun(in: context, daysAgo: 4, distanceMeters: 5_000, durationSeconds: 1_200, type: .tempo)
        // A slow long run, which must not drag the prediction down.
        let easy = makeRun(in: context, daysAgo: 2, distanceMeters: 20_000, durationSeconds: 7_800, type: .longRun)

        let withQuality = resolve(profile: profile, runs: [quality, easy])?.predictedFinishSeconds
        let easyOnly = resolve(profile: profile, runs: [easy])?.predictedFinishSeconds

        #expect(withQuality != nil)
        #expect(abs((withQuality ?? 0) - 1_200) < 60)
        #expect(easyOnly == nil)
    }

    @Test("With no quality history the profile's own 5 K estimate answers instead")
    func predictionFallsBackToProfileEstimate() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, race: .fiveK, raceIn: 10, goalSeconds: 1_200, estimated5K: 1_260)

        #expect(resolve(profile: profile)?.predictedFinishSeconds != nil)
    }

    @Test("A quality effort older than the lookback window is not current fitness")
    func predictionIgnoresStaleEfforts() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, race: .fiveK, raceIn: 10, goalSeconds: 1_200)
        let stale = makeRun(in: context, daysAgo: 80, distanceMeters: 5_000, durationSeconds: 1_200, type: .tempo)

        #expect(resolve(profile: profile, runs: [stale])?.predictedFinishSeconds == nil)
    }

    // MARK: - Dashboard placement

    @Test("The dashboard carries the race only once it is close, and briefly after")
    func dashboardWindow() {
        let context = TestStore.makeContext()

        #expect(resolve(profile: makeProfile(in: context, raceIn: 30))?.deservesDashboardPlacement == false)
        #expect(resolve(profile: makeProfile(in: context, raceIn: 14))?.deservesDashboardPlacement == true)
        #expect(resolve(profile: makeProfile(in: context, raceIn: 0))?.deservesDashboardPlacement == true)
        #expect(resolve(profile: makeProfile(in: context, raceIn: -3))?.deservesDashboardPlacement == true)
        #expect(resolve(profile: makeProfile(in: context, raceIn: -9))?.deservesDashboardPlacement == false)
    }
}
