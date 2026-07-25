import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers `ScheduledDayResolver`, the pure replacement for the dashboard's inline
/// day resolution: a day can hold more than one session and every one of them must
/// be reachable (N12), and a session missed by a day must still be startable (N24).
@MainActor
struct ScheduledDayResolverTests {

    private let monday = Date(timeIntervalSince1970: 1_700_000_000)   // fixed anchor

    /// Builds a one-week plan whose Monday holds the given sessions.
    private func makePlan(
        in context: ModelContext,
        sessions: [(offsetDays: Int, type: WorkoutType, completed: Bool)]
    ) throws -> TrainingPlan {
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: monday,
            endDate: monday.addingTimeInterval(6 * 86_400)
        )
        plan.isActive = true
        context.insert(plan)

        let week = TrainingWeek(weekNumber: 1, startDate: monday, phase: .base, targetDistanceKm: 20)
        context.insert(week)
        week.plan = plan

        for session in sessions {
            let workout = ScheduledWorkout(
                scheduledDate: monday.addingTimeInterval(Double(session.offsetDays) * 86_400),
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

    @Test("A day holding a run and a gym session resolves to both, runs first")
    func pairedDayResolvesToBothSessions() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        // Insert strength first so a first-match resolver would have returned it.
        let plan = try makePlan(in: context, sessions: [
            (0, .strength, false),
            (0, .tempo, false),
        ])

        let sessions = ScheduledDayResolver.sessions(on: monday, in: plan)
        #expect(sessions.count == 2)
        #expect(sessions.first?.workoutType == .tempo)
        #expect(sessions.last?.workoutType == .strength)
    }

    @Test("Rest days are excluded from sessions but present in workouts")
    func restDayIsNotASession() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [(0, .rest, false)])

        #expect(ScheduledDayResolver.sessions(on: monday, in: plan).isEmpty)
        #expect(ScheduledDayResolver.workouts(on: monday, in: plan).count == 1)
    }

    @Test("A day outside the plan, and a nil plan, resolve to nothing")
    func emptyDaysResolveToNothing() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [(0, .easy, false)])

        #expect(ScheduledDayResolver.sessions(on: monday.addingTimeInterval(20 * 86_400), in: plan).isEmpty)
        #expect(ScheduledDayResolver.sessions(on: monday, in: nil).isEmpty)
    }

    @Test("Ordering is stable across repeated resolutions")
    func orderingIsStable() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [
            (0, .crossTraining, false),
            (0, .strength, false),
            (0, .easy, false),
        ])

        let first = ScheduledDayResolver.sessions(on: monday, in: plan).map(\.workoutType)
        let second = ScheduledDayResolver.sessions(on: monday, in: plan).map(\.workoutType)
        #expect(first == [.easy, .strength, .crossTraining])
        #expect(first == second)
    }

    @Test("A session can be started today and one day late, but not earlier or ahead")
    func startWindowMatchesTheLinkerTolerance() {
        let calendar = Calendar.current
        let today = Date(timeIntervalSince1970: 1_700_100_000)

        #expect(ScheduledDayResolver.canStart(workoutScheduledOn: today, now: today, calendar: calendar))
        #expect(
            ScheduledDayResolver.canStart(
                workoutScheduledOn: today.addingTimeInterval(-86_400),
                now: today,
                calendar: calendar
            )
        )
        // Two days late is the recovery card's job, not a start button.
        #expect(
            !ScheduledDayResolver.canStart(
                workoutScheduledOn: today.addingTimeInterval(-2 * 86_400),
                now: today,
                calendar: calendar
            )
        )
        // Tomorrow stays unstartable so the plan isn't run out of order.
        #expect(
            !ScheduledDayResolver.canStart(
                workoutScheduledOn: today.addingTimeInterval(86_400),
                now: today,
                calendar: calendar
            )
        )
    }

    @Test("The start window is judged by calendar day, not by elapsed hours")
    func startWindowIsCalendarBased() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone

        // 23:30 yesterday and 00:30 today are an hour apart but different days —
        // and yesterday is inside the window, so both must be startable.
        let lateLastNight = Date(timeIntervalSince1970: 1_700_004_600)     // 2023-11-14 23:30 UTC
        let justAfterMidnight = Date(timeIntervalSince1970: 1_700_008_200) // 2023-11-15 00:30 UTC

        #expect(
            ScheduledDayResolver.canStart(
                workoutScheduledOn: lateLastNight,
                now: justAfterMidnight,
                calendar: calendar
            )
        )
        // The reverse — a workout scheduled for the coming day — is not startable.
        #expect(
            !ScheduledDayResolver.canStart(
                workoutScheduledOn: justAfterMidnight,
                now: lateLastNight,
                calendar: calendar
            )
        )
    }

    // MARK: - Day state (N23)

    /// "Nothing scheduled" is three different things, and the dashboard used to render
    /// the same "Rest day · Recovery is part of training" card for all of them.
    @Test("An empty day inside the plan is a rest day")
    func emptyDayInsidePlanIsRest() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [(0, .tempo, false)])

        // Tuesday holds nothing but is inside the plan's week.
        let tuesday = monday.addingTimeInterval(86_400)
        #expect(ScheduledDayResolver.dayState(on: tuesday, in: plan) == .rest)
    }

    @Test("An explicit rest row is a rest day, not scheduled work")
    func explicitRestRowIsRest() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [(0, .rest, false)])

        #expect(ScheduledDayResolver.dayState(on: monday, in: plan) == .rest)
    }

    @Test("A date past the plan's end is outside it, not a rest day")
    func dateBeyondPlanIsOutside() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [(0, .tempo, false)])

        let nextMonth = monday.addingTimeInterval(40 * 86_400)
        #expect(ScheduledDayResolver.dayState(on: nextMonth, in: plan) == .outsidePlan)
        let beforeStart = monday.addingTimeInterval(-86_400)
        #expect(ScheduledDayResolver.dayState(on: beforeStart, in: plan) == .outsidePlan)
    }

    @Test("With no plan, no day is a rest day")
    func noPlanIsItsOwnState() {
        #expect(ScheduledDayResolver.dayState(on: monday, in: nil) == .noPlan)
    }

    @Test("A day with work is scheduled")
    func dayWithWorkIsScheduled() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, sessions: [(0, .tempo, false)])

        #expect(ScheduledDayResolver.dayState(on: monday, in: plan) == .scheduled)
    }
}
