import Foundation
import Testing
@testable import Stride

/// N6's remainder: holding the race workout still was never enough — the rest of the
/// block slid straight over race day. These pin the clamp that stops it.
struct MissedWorkoutShiftTests {

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        Calendar.current.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        ) ?? .now
    }

    // MARK: Open-ended plans

    @Test("An open-ended plan applies the whole requested shift")
    func noRaceDateAppliesRequest() {
        let outcome = MissedWorkoutShift.resolve(
            requestedDays: 6,
            lastMovableDate: day(2027, 4, 1),
            raceDate: nil
        )

        #expect(outcome.appliedDays == 6)
        #expect(outcome.wasClampedByRace == false)
        #expect(outcome.isNoOp == false)
    }

    @Test("Nothing left to move is a no-op, race date or not")
    func nothingMovableIsNoOp() {
        let outcome = MissedWorkoutShift.resolve(
            requestedDays: 4,
            lastMovableDate: nil,
            raceDate: day(2027, 4, 20)
        )

        #expect(outcome.isNoOp)
        // Nothing moved because there was nothing to move — not because of the race.
        #expect(outcome.wasBlockedByRace == false)
    }

    @Test("A zero or negative request is a no-op")
    func nonPositiveRequestIsNoOp() {
        for requested in [0, -3] {
            let outcome = MissedWorkoutShift.resolve(
                requestedDays: requested,
                lastMovableDate: day(2027, 4, 1),
                raceDate: nil
            )
            #expect(outcome.requestedDays == 0)
            #expect(outcome.isNoOp)
            #expect(outcome.wasBlockedByRace == false)
        }
    }

    // MARK: Race-date headroom

    @Test("A shift that still lands before race day is applied in full")
    func shiftWithinHeadroomIsUnchanged() {
        // Last movable session 10 days out, so 9 days of headroom.
        let outcome = MissedWorkoutShift.resolve(
            requestedDays: 4,
            lastMovableDate: day(2027, 4, 10),
            raceDate: day(2027, 4, 20)
        )

        #expect(outcome.appliedDays == 4)
        #expect(outcome.wasClampedByRace == false)
    }

    @Test("A shift that would overrun race day is clamped to the room that exists")
    func shiftIsClampedToRaceDate() {
        // Last movable session 3 days before the race: it may travel 2 days and still
        // land the day before. The runner asked for 6.
        let outcome = MissedWorkoutShift.resolve(
            requestedDays: 6,
            lastMovableDate: day(2027, 4, 17),
            raceDate: day(2027, 4, 20)
        )

        #expect(outcome.requestedDays == 6)
        #expect(outcome.appliedDays == 2)
        #expect(outcome.wasClampedByRace)
        #expect(outcome.wasBlockedByRace == false)
    }

    @Test("A session already the day before the race cannot move at all")
    func noHeadroomBlocksTheShift() {
        let outcome = MissedWorkoutShift.resolve(
            requestedDays: 3,
            lastMovableDate: day(2027, 4, 19),
            raceDate: day(2027, 4, 20)
        )

        #expect(outcome.appliedDays == 0)
        #expect(outcome.isNoOp)
        #expect(outcome.wasBlockedByRace)
    }

    @Test("A session already on or past race day yields no headroom rather than a negative shift")
    func sessionOnOrPastRaceDayIsFlooredAtZero() {
        for last in [day(2027, 4, 20), day(2027, 4, 25)] {
            let outcome = MissedWorkoutShift.resolve(
                requestedDays: 5,
                lastMovableDate: last,
                raceDate: day(2027, 4, 20)
            )
            #expect(outcome.appliedDays == 0)
            #expect(outcome.wasBlockedByRace)
        }
    }

    @Test("Headroom is counted in calendar days, not elapsed hours")
    func headroomIgnoresTimeOfDay() {
        // A 19:00 long run and an 06:00 race gun time two days later are two calendar
        // days apart, so the run may travel one day. Measured in hours it would be
        // 35 — a day and a half — and round the wrong way.
        let outcome = MissedWorkoutShift.resolve(
            requestedDays: 4,
            lastMovableDate: day(2027, 4, 18, hour: 19),
            raceDate: day(2027, 4, 20, hour: 6)
        )

        #expect(outcome.appliedDays == 1)
        #expect(outcome.wasClampedByRace)
    }
}
