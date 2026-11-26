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

    @Test("The run session rides along in the context and comes back the same")
    func runSessionRoundTrips() throws {
        let run = WatchRunSession(
            sessionID: UUID(),
            scheduledDate: now,
            title: "Interval",
            targetDistanceMeters: 8_000,
            targetPaceLowerSecondsPerKm: 240,
            targetPaceUpperSecondsPerKm: 250,
            structure: intervals,
            usesRunWalkCues: false,
            maxHeartRateBPM: 186,
            usesMetricUnits: true
        )
        let original = WatchContext(snapshot: snapshot(nextOn: now), startableWorkout: Data([1]), runSession: run)

        let decoded = try #require(WatchContext(applicationContext: try original.applicationContext()))

        #expect(decoded == original)
        #expect(decoded.runSession?.guidedState() != nil)
    }

    @Test("A run session that no longer decodes is dropped, and the glance survives")
    func unreadableRunSessionIsDropped() throws {
        var dictionary = try WatchContext(snapshot: snapshot(nextOn: now), startableWorkout: Data([1])).applicationContext()
        dictionary[WatchContext.Key.runSession] = Data("{}".utf8)

        let decoded = try #require(WatchContext(applicationContext: dictionary))

        #expect(decoded.runSession == nil)
        #expect(decoded.startableWorkout == Data([1]))
    }

    private var intervals: WorkoutStructure {
        WorkoutStructure(
            warmup: WorkoutSegment(distanceMeters: 2_000, label: "Warm-up"),
            mainSets: [WorkoutSet(
                repetitions: 6,
                workSegment: WorkoutSegment(distanceMeters: 800, targetPaceSecondsPerKm: 240, label: "Rep"),
                recoverySegment: WorkoutSegment(durationSeconds: 120, label: "Recovery jog"),
                label: "VO2max Intervals"
            )],
            cooldown: WorkoutSegment(distanceMeters: 1_500, label: "Cool-down"),
            totalEstimatedDistanceMeters: 8_300,
            totalEstimatedDurationSeconds: 2_700
        )
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

    @Test("No overdue, rest or completed session is ever sent")
    func overdueRestAndDoneAreNotSent() {
        let overdue = session(on: offset(-1))
        let rest = session(on: now, type: .rest)
        let done = session(on: now)
        done.isCompleted = true

        for workout in [overdue, rest, done] {
            #expect(WatchSyncService.startableWorkoutData(
                for: workout, unit: .metric, now: now, calendar: calendar
            ) == nil)
        }
        #expect(WatchSyncService.startableWorkoutData(
            for: nil, unit: .metric, now: now, calendar: calendar
        ) == nil)
    }

    /// A morning runner whose phone app last ran the evening before still gets Start: the
    /// phone sends tomorrow's session the night before, and the watch holds the button back
    /// until its day (P2.2).
    @Test("Tomorrow's session is sent ahead, and startable only once its day comes (P2.2)")
    func tomorrowsSessionIsSentAhead() throws {
        let tomorrow = session(on: offset(1))

        let data = try #require(
            WatchSyncService.startableWorkoutData(for: tomorrow, unit: .metric, now: now, calendar: calendar)
        )
        #expect(try WorkoutPlan(from: data).id == tomorrow.id)

        let watch = WatchContext(snapshot: snapshot(nextOn: offset(1)), startableWorkout: data)
        #expect(!watch.canStart(asOf: now, calendar: calendar))
        #expect(watch.canStart(asOf: offset(1), calendar: calendar))
    }

    // MARK: Run session (phone side)

    @Test("Today's session becomes a run session with its id, pace band, steps and max HR")
    func todaysSessionBecomesARunSession() throws {
        let workout = session(on: now, type: .interval)
        workout.targetPaceLowerBound = 240
        workout.targetPaceUpperBound = 250
        workout.workoutStructure = intervals

        let run = try #require(WatchSyncService.runSession(
            for: workout, unit: .imperial, maxHeartRateBPM: 186, now: now, calendar: calendar
        ))

        #expect(run.sessionID == workout.id)
        #expect(run.targetPaceLowerSecondsPerKm == 240)
        #expect(run.targetPaceUpperSecondsPerKm == 250)
        #expect(run.structure == intervals)
        #expect(run.maxHeartRateBPM == 186)
        #expect(!run.usesMetricUnits)
        #expect(run.guidedState() != nil)
    }

    @Test("No overdue, rest or completed session becomes a run session, and no zero max HR is sent")
    func runSessionFollowsTheSameRules() throws {
        let overdue = session(on: offset(-1))
        let rest = session(on: now, type: .rest)
        let done = session(on: now)
        done.isCompleted = true

        for workout in [overdue, rest, done] {
            #expect(WatchSyncService.runSession(
                for: workout, unit: .metric, maxHeartRateBPM: 186, now: now, calendar: calendar
            ) == nil)
        }
        let easy = try #require(WatchSyncService.runSession(
            for: session(on: now), unit: .metric, maxHeartRateBPM: 0, now: now, calendar: calendar
        ))
        #expect(easy.maxHeartRateBPM == nil)
        #expect(easy.guidedState() == nil)
    }
}
