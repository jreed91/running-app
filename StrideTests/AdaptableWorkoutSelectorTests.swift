import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers `AdaptableWorkoutSelector`, the one definition of "which sessions may the AI
/// coach rewrite". Smart Adapt and the run summary's apply-coach-feedback path each had
/// their own copy of this filter (D1), written from opposite directions — one listing
/// the excluded types, one the allowed ones.
@MainActor
struct AdaptableWorkoutSelectorTests {

    /// A fixed mid-morning Monday. Anchored through `Calendar.current` rather than an
    /// epoch offset so "twelve hours later" is still the same calendar day in whatever
    /// timezone the test runs in.
    private let monday = Calendar.current.date(
        from: DateComponents(year: 2027, month: 3, day: 15, hour: 9)
    ) ?? .now

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: monday) ?? monday
    }

    /// A three-week plan holding the given sessions, all relative to `monday`.
    private func makePlan(
        in context: ModelContext,
        sessions: [(offsetDays: Int, type: WorkoutType, completed: Bool)]
    ) throws -> TrainingPlan {
        let plan = TrainingPlan(
            targetRace: .halfMarathon,
            goalTimeSeconds: 7_200,
            startDate: monday,
            endDate: day(20)
        )
        plan.isActive = true
        context.insert(plan)

        let week = TrainingWeek(weekNumber: 1, startDate: monday, phase: .base, targetDistanceKm: 40)
        context.insert(week)
        week.plan = plan

        for session in sessions {
            let workout = ScheduledWorkout(
                scheduledDate: day(session.offsetDays),
                workoutType: session.type,
                targetDistanceMeters: 8_000
            )
            workout.isCompleted = session.completed
            context.insert(workout)
            workout.week = week
        }

        try context.save()
        return plan
    }

    // MARK: Type scoping

    @Test("Only run sessions are adaptable — never strength, cross-training, or rest")
    func nonRunSessionsAreExcluded() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [
            (1, .easy, false),
            (1, .strength, false),
            (2, .crossTraining, false),
            (3, .rest, false),
            (4, .tempo, false),
        ])

        let adaptable = AdaptableWorkoutSelector.adaptableWorkouts(in: plan, now: monday)

        #expect(adaptable.map(\.workoutType) == [.easy, .tempo])
    }

    @Test("The race is never adaptable, even though it is a run")
    func raceIsExcluded() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [
            (5, .race, false),
            (2, .longRun, false),
        ])

        let adaptable = AdaptableWorkoutSelector.adaptableWorkouts(in: plan, now: monday)

        #expect(adaptable.map(\.workoutType) == [.longRun])
        #expect(AdaptableWorkoutSelector.isAdaptableType(.race) == false)
    }

    @Test("Every run type except the race is adaptable")
    func adaptableTypes() {
        for type in WorkoutType.allCases {
            let expected = type.isRunType && type != .race
            #expect(AdaptableWorkoutSelector.isAdaptableType(type) == expected)
        }
    }

    // MARK: Time and completion scoping

    @Test("Completed sessions are left alone so the record of what was run is not rewritten")
    func completedSessionsAreExcluded() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [
            (1, .tempo, true),
            (2, .easy, false),
        ])

        let adaptable = AdaptableWorkoutSelector.adaptableWorkouts(in: plan, now: monday)

        #expect(adaptable.count == 1)
        #expect(adaptable.first?.workoutType == .easy)
    }

    @Test("Past sessions are excluded, and today's is kept")
    func pastSessionsAreExcluded() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [
            (-2, .easy, false),
            (0, .tempo, false),
            (2, .longRun, false),
        ])

        // "Now" is the Monday itself: today's session is still ahead of the runner.
        let adaptable = AdaptableWorkoutSelector.adaptableWorkouts(in: plan, now: monday)

        #expect(adaptable.map(\.workoutType) == [.tempo, .longRun])
    }

    @Test("A session earlier today is still adaptable — the day is the boundary, not the hour")
    func earlierTodayIsStillAdaptable() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [(0, .tempo, false)])

        // The session is scheduled at the anchor instant; "now" is twelve hours later.
        let adaptable = AdaptableWorkoutSelector.adaptableWorkouts(
            in: plan,
            now: monday.addingTimeInterval(12 * 3_600)
        )

        #expect(adaptable.count == 1)
    }

    @Test("Results are ordered earliest first regardless of relationship order")
    func resultsAreSortedByDate() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [
            (6, .longRun, false),
            (1, .easy, false),
            (3, .tempo, false),
        ])

        let adaptable = AdaptableWorkoutSelector.adaptableWorkouts(in: plan, now: monday)

        #expect(adaptable.map(\.scheduledDate) == [day(1), day(3), day(6)])
    }

    // MARK: The `after` bound

    @Test("Feedback on a run never rewrites the session that run fulfilled")
    func afterBoundExcludesTheCompletedSession() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [
            (1, .tempo, false),
            (4, .easy, false),
        ])

        // The runner just finished the Tuesday tempo; its own day must not be the
        // target of its own feedback.
        let next = AdaptableWorkoutSelector.nextAdaptableWorkout(in: plan, after: day(1), now: monday)

        #expect(next?.scheduledDate == day(4))
    }

    @Test("Without an `after` bound the next adaptable session is simply the soonest")
    func nextIsTheSoonest() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [
            (4, .easy, false),
            (1, .tempo, false),
        ])

        #expect(AdaptableWorkoutSelector.nextAdaptableWorkout(in: plan, now: monday)?.scheduledDate == day(1))
    }

    // MARK: Absent plan

    @Test("No plan yields no candidates rather than trapping")
    func noPlanYieldsNothing() {
        #expect(AdaptableWorkoutSelector.adaptableWorkouts(in: nil).isEmpty)
        #expect(AdaptableWorkoutSelector.nextAdaptableWorkout(in: nil) == nil)
    }

    @Test("A plan whose remaining sessions are all non-run yields no candidates")
    func exhaustedPlanYieldsNothing() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [
            (1, .strength, false),
            (2, .rest, false),
        ])

        #expect(AdaptableWorkoutSelector.nextAdaptableWorkout(in: plan, now: monday) == nil)
    }
}
