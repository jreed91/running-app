import Testing
import Foundation
@testable import Stride

struct WorkoutKitFireDateTests {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return calendar.date(from: c)!
    }

    @Test("A workout anchors to the end of its scheduled day")
    func anchorsToEndOfDay() {
        let scheduled = date(2026, 5, 25) // midnight
        let now = date(2026, 5, 21, 9, 30)

        let fire = HealthKitRepository.workoutKitFireDate(for: scheduled, now: now, calendar: calendar)

        #expect(fire == date(2026, 5, 25, 23, 59))
    }

    @Test("Today's workout stays scheduled for later today regardless of the current time")
    func todayStaysVisibleAllDay() {
        let scheduled = date(2026, 5, 21) // today at midnight

        // Whether the app opens early morning or mid-afternoon, today's workout resolves to a
        // future instant on the same day, so it remains visible in the Workout app.
        for hour in [0, 7, 14, 22] {
            let now = date(2026, 5, 21, hour, 0)
            let fire = HealthKitRepository.workoutKitFireDate(for: scheduled, now: now, calendar: calendar)

            #expect(fire == date(2026, 5, 21, 23, 59))
            #expect((fire ?? .distantPast) > now)
        }
    }

    @Test("A past-day workout is not scheduled")
    func pastDayReturnsNil() {
        let scheduled = date(2026, 5, 19) // two days ago
        let now = date(2026, 5, 21, 9, 30)

        let fire = HealthKitRepository.workoutKitFireDate(for: scheduled, now: now, calendar: calendar)

        #expect(fire == nil)
    }

    @Test("Today's workout is dropped only in the final minute of the day")
    func todayDroppedAtVeryEndOfDay() {
        let scheduled = date(2026, 5, 21)
        let now = date(2026, 5, 21, 23, 59)

        let fire = HealthKitRepository.workoutKitFireDate(for: scheduled, now: now, calendar: calendar)

        #expect(fire == nil)
    }

    @Test("The resolved instant is never in the past")
    func neverSchedulesInThePast() {
        let scheduled = date(2026, 5, 21)
        let now = date(2026, 5, 21, 18, 0)

        let fire = HealthKitRepository.workoutKitFireDate(for: scheduled, now: now, calendar: calendar)

        #expect(fire != nil)
        #expect((fire ?? .distantPast) > now)
    }
}

/// The ids the single-workout resync clears before it re-schedules the coach's edit.
@MainActor
struct WorkoutKitPlanIDTests {

    @Test("A workout is found under its own id even after an edit cleared the recorded one")
    func ownIDSurvivesAnEdit() {
        let workout = ScheduledWorkout(scheduledDate: .now, workoutType: .easy, targetDistanceMeters: 5_000)
        workout.healthKitPlanID = workout.id.uuidString

        // What the coach's update does: it clears the recorded id, and the Watch still
        // holds the old composition under the workout's own id.
        workout.applyAdaptation(from: ScheduledWorkout(scheduledDate: .now, workoutType: .easy))

        #expect(workout.healthKitPlanID == nil)
        #expect(HealthKitRepository.workoutKitPlanIDs(for: workout) == [workout.id.uuidString])
    }

    @Test("An id recorded by an older sync is cleared too")
    func recordedIDIsIncluded() {
        let workout = ScheduledWorkout(scheduledDate: .now, workoutType: .tempo)
        let legacy = UUID().uuidString
        workout.healthKitPlanID = legacy

        #expect(HealthKitRepository.workoutKitPlanIDs(for: workout) == [workout.id.uuidString, legacy])
    }
}
