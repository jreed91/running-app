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

    @Test("A future-day workout anchors to the 7 AM morning slot")
    func futureDayAnchorsToMorning() {
        let scheduled = date(2026, 5, 25) // midnight, several days out
        let now = date(2026, 5, 21, 9, 30)

        let fire = HealthKitRepository.workoutKitFireDate(for: scheduled, now: now, calendar: calendar)

        #expect(fire == date(2026, 5, 25, HealthKitRepository.scheduledWorkoutHour, 0))
    }

    @Test("Today's workout opened before the morning anchor still uses the 7 AM slot")
    func todayBeforeMorningUsesAnchor() {
        let scheduled = date(2026, 5, 21) // today at midnight
        let now = date(2026, 5, 21, 5, 0) // before 7 AM

        let fire = HealthKitRepository.workoutKitFireDate(for: scheduled, now: now, calendar: calendar)

        #expect(fire == date(2026, 5, 21, HealthKitRepository.scheduledWorkoutHour, 0))
    }

    @Test("Today's workout opened after the morning anchor falls forward to just after now")
    func todayAfterMorningFallsForward() {
        let scheduled = date(2026, 5, 21) // today at midnight
        let now = date(2026, 5, 21, 9, 30) // past 7 AM

        let fire = HealthKitRepository.workoutKitFireDate(for: scheduled, now: now, calendar: calendar)

        // Must be in the future so WorkoutKit accepts it, and must remain on today.
        #expect(fire == now.addingTimeInterval(60))
        #expect(fire.map { calendar.isDate($0, inSameDayAs: now) } == true)
    }

    @Test("A past-day workout is not scheduled")
    func pastDayReturnsNil() {
        let scheduled = date(2026, 5, 19) // two days ago
        let now = date(2026, 5, 21, 9, 30)

        let fire = HealthKitRepository.workoutKitFireDate(for: scheduled, now: now, calendar: calendar)

        #expect(fire == nil)
    }

    @Test("A midnight scheduled date never resolves to a past instant")
    func neverSchedulesInThePast() {
        let scheduled = date(2026, 5, 21) // today at midnight
        let now = date(2026, 5, 21, 23, 59)

        let fire = HealthKitRepository.workoutKitFireDate(for: scheduled, now: now, calendar: calendar)

        #expect(fire != nil)
        #expect((fire ?? .distantPast) > now)
    }
}
