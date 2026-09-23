import Foundation
import SwiftData
import Testing
@preconcurrency import WorkoutKit
@testable import Stride

// MARK: - Watch context tests
//
// The watch app (B3) draws whatever `WatchContext` the phone last sent, so the envelope's
// round trip and the "may this be started?" rules are the whole of what can be tested
// without a watch. Same pinned UTC calendar and noon `now` as `WidgetSnapshotBuilderTests`,
// because "today" is day-bucketing.

@MainActor
struct WatchContextTests {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Noon on Thursday 2026-07-23.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 12))!
    }

    private func offset(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: now)!
    }

    private func snapshot(nextOn date: Date, isRest: Bool = false) -> WidgetSnapshot {
        var snapshot = WidgetSnapshot.sample(now: now)
        snapshot.nextWorkout?.scheduledDate = date
        snapshot.nextWorkout?.isRest = isRest
        return snapshot
    }

    /// Held for the test's lifetime so the sessions inserted into it outlive the call that
    /// made them. See `TestStore`.
    private let context = TestStore.makeContext()

    private func session(on date: Date, type: WorkoutType = .easy) -> ScheduledWorkout {
        let workout = ScheduledWorkout(
            scheduledDate: date,
            workoutType: type,
            targetDistanceMeters: 8_000
        )
        context.insert(workout)
        return workout
    }

    // MARK: Envelope

    @Test("The application context round-trips the snapshot and the workout")
    func applicationContextRoundTrips() throws {
        let original = WatchContext(snapshot: snapshot(nextOn: now), startableWorkout: Data([1, 2, 3]))

        let decoded = WatchContext(applicationContext: try original.applicationContext())

        #expect(decoded == original)
    }

    @Test("A context with no workout sends no workout key")
    func noWorkoutNoKey() throws {
        let dictionary = try WatchContext(snapshot: snapshot(nextOn: now)).applicationContext()

        #expect(dictionary[WatchContext.Key.startableWorkout] == nil)
        #expect(WatchContext(applicationContext: dictionary)?.startableWorkout == nil)
    }

    @Test("A context without a readable snapshot is no context")
    func unreadableSnapshotIsNil() {
        #expect(WatchContext(applicationContext: [:]) == nil)
        #expect(WatchContext(applicationContext: [WatchContext.Key.snapshot: Data("{}".utf8)]) == nil)
    }

    // MARK: Start button

    @Test("Start is offered for today's session")
    func canStartToday() {
        let watch = WatchContext(snapshot: snapshot(nextOn: now), startableWorkout: Data([1]))
        #expect(watch.canStart(asOf: now, calendar: calendar))
    }

    @Test("Start goes away once the day the session was for has passed")
    func cannotStartYesterdaysContextTomorrow() {
        let watch = WatchContext(snapshot: snapshot(nextOn: now), startableWorkout: Data([1]))
        #expect(!watch.canStart(asOf: offset(1), calendar: calendar))
    }

    @Test("Start is not offered without a workout, or on a rest day")
    func cannotStartWithoutWorkoutOrOnRest() {
        #expect(!WatchContext(snapshot: snapshot(nextOn: now)).canStart(asOf: now, calendar: calendar))
        let rest = WatchContext(snapshot: snapshot(nextOn: now, isRest: true), startableWorkout: Data([1]))
        #expect(!rest.canStart(asOf: now, calendar: calendar))
    }

    // MARK: Phone side

    @Test("Today's session becomes a WorkoutKit plan carrying the session's own id")
    func todaysSessionBecomesAPlan() throws {
        let workout = session(on: now)

        let data = try #require(
            WatchSyncService.startableWorkoutData(for: workout, unit: .metric, now: now, calendar: calendar)
        )

        #expect(try WorkoutPlan(from: data).id == workout.id)
    }

    @Test("Only today's outstanding, non-rest session is startable")
    func onlyTodaysSessionIsStartable() {
        let tomorrow = session(on: offset(1))
        let overdue = session(on: offset(-1))
        let rest = session(on: now, type: .rest)
        let done = session(on: now)
        done.isCompleted = true

        for workout in [tomorrow, overdue, rest, done] {
            #expect(WatchSyncService.startableWorkoutData(
                for: workout, unit: .metric, now: now, calendar: calendar
            ) == nil)
        }
        #expect(WatchSyncService.startableWorkoutData(
            for: nil, unit: .metric, now: now, calendar: calendar
        ) == nil)
    }
}
