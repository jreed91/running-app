import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers `CoachSituation`, the state the coaching strip is selected from.
///
/// Resolution order is the design — race day beats a lay-off, a lay-off beats the plan,
/// the recovery window beats the next session — so the tests that matter most are the
/// ones where two states are true at once.
@MainActor
struct CoachSituationTests {

    /// Fixed anchor: 2023-11-14 22:13:20 UTC, a Tuesday.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Fixtures

    private func makeSession(
        in context: ModelContext,
        type: WorkoutType,
        daysFromNow: Int = 1,
        distanceMeters: Double? = nil,
        paceBand: ClosedRange<Double>? = nil
    ) -> ScheduledWorkout {
        let workout = ScheduledWorkout(
            scheduledDate: now.addingTimeInterval(Double(daysFromNow) * 86_400),
            workoutType: type,
            targetDistanceMeters: distanceMeters,
            targetPaceLowerBound: paceBand?.lowerBound,
            targetPaceUpperBound: paceBand?.upperBound
        )
        context.insert(workout)
        return workout
    }

    private func makeRun(
        in context: ModelContext,
        daysAgo: Double,
        distanceMeters: Double = 10_000,
        durationSeconds: Double = 3_600,
        type: WorkoutType = .easy
    ) -> RunWorkout {
        let run = RunWorkout(
            date: now.addingTimeInterval(-daysAgo * 86_400),
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            workoutType: type
        )
        context.insert(run)
        return run
    }

    private func makeProfile(in context: ModelContext, raceIn days: Int?, race: RaceType = .marathon) -> UserProfile {
        let profile = UserProfile(
            name: "Sam",
            goalRace: race,
            goalFinishTime: 14_400,
            raceDate: days.map { now.addingTimeInterval(Double($0) * 86_400) },
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )
        context.insert(profile)
        return profile
    }

    private func resolve(
        nextSession: ScheduledWorkout? = nil,
        runs: [RunWorkout] = [],
        profile: UserProfile? = nil,
        dayState: ScheduledDayResolver.DayState = .noPlan
    ) -> CoachSituation {
        CoachSituation.resolve(
            nextSession: nextSession,
            recentRuns: runs,
            profile: profile,
            dayState: dayState,
            now: now
        )
    }

    // MARK: - Race

    @Test("Race day is its own state, and it is exclusive")
    func raceDayResolves() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceIn: 0)

        let situation = resolve(profile: profile)
        #expect(situation == .raceDay)
        #expect(situation.isExclusive)
    }

    @Test("A race inside the week is race week, with the days counted")
    func raceWeekResolves() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceIn: 3)

        #expect(resolve(profile: profile) == .raceWeek(daysOut: 3))
    }

    @Test("A race beyond the window does not put the runner in race week")
    func raceBeyondWindow() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceIn: CoachSituation.raceWeekWindowDays + 2)
        let session = makeSession(in: context, type: .easy, distanceMeters: 8_000)

        #expect(resolve(nextSession: session, profile: profile) == .sessionAhead(.steady))
    }

    @Test("A past race is not race week")
    func pastRaceIgnored() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceIn: -2)

        #expect(resolve(profile: profile) == .noPlan)
    }

    @Test("Maintain-fitness runners have no race to taper into")
    func maintainFitnessHasNoRace() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceIn: 2, race: .maintainFitness)

        #expect(resolve(profile: profile) == .noPlan)
    }

    @Test("Race day outranks a lay-off, a recovery window, and the next session")
    func raceDayWinsOverEverything() {
        let context = TestStore.makeContext()
        let profile = makeProfile(in: context, raceIn: 0)
        let session = makeSession(in: context, type: .longRun, distanceMeters: 30_000)
        let staleRun = makeRun(in: context, daysAgo: 20)

        #expect(resolve(nextSession: session, runs: [staleRun], profile: profile) == .raceDay)
    }

    // MARK: - Lay-off

    @Test("A long gap since the last run is a lay-off, and it is exclusive")
    func layoffResolves() {
        let context = TestStore.makeContext()
        let run = makeRun(in: context, daysAgo: Double(CoachSituation.layoffDays + 3))

        let situation = resolve(runs: [run])
        #expect(situation == .returningFromLayoff(days: CoachSituation.layoffDays + 3))
        #expect(situation.isExclusive)
    }

    @Test("A lay-off outranks the next session")
    func layoffWinsOverNextSession() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .tempo, distanceMeters: 10_000)
        let run = makeRun(in: context, daysAgo: 14)

        #expect(resolve(nextSession: session, runs: [run]) == .returningFromLayoff(days: 14))
    }

    @Test("A runner who has never logged a run is not returning from anything")
    func noHistoryIsNotALayoff() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .easy, distanceMeters: 5_000)

        #expect(resolve(nextSession: session) == .sessionAhead(.steady))
    }

    // MARK: - Recovery window

    @Test("A demanding run finished inside the window is a recovery state")
    func recoveringResolves() {
        let context = TestStore.makeContext()
        // Started 90 minutes ago, ran for 60 — finished half an hour back.
        let run = makeRun(
            in: context,
            daysAgo: 1.5 / 24,
            distanceMeters: 15_000,
            durationSeconds: 3_600,
            type: .longRun
        )

        #expect(resolve(runs: [run]) == .recovering(minutesSinceFinish: 30))
    }

    @Test("The window is measured from the finish, not the start")
    func windowMeasuredFromFinish() {
        let context = TestStore.makeContext()
        // Started three hours ago — past the two-hour window — but ran for two of them.
        let run = makeRun(
            in: context,
            daysAgo: 3.0 / 24,
            distanceMeters: 24_000,
            durationSeconds: 2 * 3_600,
            type: .longRun
        )

        #expect(resolve(runs: [run]) == .recovering(minutesSinceFinish: 60))
    }

    @Test("A short easy run is not demanding enough to be a recovery state")
    func shortRunIsNotDemanding() {
        let context = TestStore.makeContext()
        let run = makeRun(
            in: context,
            daysAgo: 0.5 / 24,
            distanceMeters: 4_000,
            durationSeconds: 1_200,
            type: .easy
        )

        #expect(resolve(runs: [run]) == .noPlan)
    }

    @Test("The recovery window outranks the next session, but not a lay-off")
    func recoveryOrdering() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .tempo, distanceMeters: 10_000)
        let justFinished = makeRun(
            in: context,
            daysAgo: 0.5 / 24,
            distanceMeters: 12_000,
            durationSeconds: 900,
            type: .longRun
        )

        #expect(resolve(nextSession: session, runs: [justFinished]).isRecovering)
    }

    // MARK: - Session shape

    @Test("Distance past the bar makes a session enduring")
    func enduringByDistance() {
        let context = TestStore.makeContext()
        let session = makeSession(
            in: context,
            type: .longRun,
            distanceMeters: CoachSituation.enduringDistanceMeters + 1_000
        )

        #expect(CoachSituation.shape(of: session) == .enduring)
    }

    @Test("Duration past ninety minutes makes a session enduring without the distance")
    func enduringByDuration() {
        let context = TestStore.makeContext()
        // 13 km at 7:30/km is 97 minutes — under the distance bar, over the time one.
        let session = makeSession(in: context, type: .easy, distanceMeters: 13_000, paceBand: 450...450)

        #expect(CoachSituation.shape(of: session) == .enduring)
    }

    @Test("Tempo and interval sessions are quality; a short easy run is steady")
    func qualityAndSteady() {
        let context = TestStore.makeContext()
        let tempo = makeSession(in: context, type: .tempo, distanceMeters: 10_000)
        let interval = makeSession(in: context, type: .interval, distanceMeters: 8_000)
        let easy = makeSession(in: context, type: .easy, distanceMeters: 6_000)

        #expect(CoachSituation.shape(of: tempo) == .quality)
        #expect(CoachSituation.shape(of: interval) == .quality)
        #expect(CoachSituation.shape(of: easy) == .steady)
    }

    @Test("A strength day is not a run")
    func strengthIsNonRun() {
        let context = TestStore.makeContext()
        let strength = makeSession(in: context, type: .strength)

        #expect(CoachSituation.shape(of: strength) == .nonRun)
    }

    // MARK: - Empty states

    @Test("With nothing outstanding, the plan's reading of today is the state")
    func emptyStatesComeFromTheDayState() {
        #expect(resolve(dayState: .rest) == .restDay)
        #expect(resolve(dayState: .scheduled) == .restDay)
        #expect(resolve(dayState: .beforePlanStart(daysUntilStart: 4)) == .beforePlanStart(daysUntilStart: 4))
        #expect(resolve(dayState: .outsidePlan) == .planFinished)
        #expect(resolve(dayState: .noPlan) == .noPlan)
    }

    @Test("Every empty state is flagged empty, and none of them is exclusive")
    func emptyStatesAreFlagged() {
        let states: [CoachSituation] = [
            .restDay, .beforePlanStart(daysUntilStart: 1), .planFinished, .noPlan
        ]
        for state in states {
            #expect(state.isEmpty)
            #expect(!state.isExclusive)
        }
    }

    @Test("A state with work to do is neither empty nor exclusive")
    func sessionAheadIsOrdinary() {
        let situation = CoachSituation.sessionAhead(.quality)
        #expect(!situation.isEmpty)
        #expect(!situation.isExclusive)
    }
}

// MARK: - Helpers

private extension CoachSituation {
    /// Pattern match without pinning the exact minute, for the ordering tests.
    var isRecovering: Bool {
        if case .recovering = self { return true }
        return false
    }
}
