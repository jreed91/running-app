import Testing
import Foundation
@testable import Stride

struct CoachProseUnitsTests {

    @Test("A pace range in kilometres is rewritten in miles for a runner who uses miles")
    func paceRangeToMiles() {
        let note = "You need to slow this run to 6:40–7:40 per km because your last session was too fast."

        #expect(
            CoachProseUnits.localized(note, to: .imperial)
                == "You need to slow this run to 10:44–12:20 per mile because your last session was too fast."
        )
    }

    @Test("Slash paces and distances keep the shape the coach wrote them in")
    func slashPaceAndDistances() {
        let note = "Run 8 km at 5:20/km, then 1.5 kilometres easy."

        #expect(CoachProseUnits.localized(note, to: .imperial) == "Run 5.0 mi at 8:35/mi, then 0.9 miles easy.")
    }

    @Test("Prose already in the runner's unit is left alone")
    func alreadyInRunnersUnit() {
        let imperial = "Easy 3.1 mi at 10:44 per mile."
        let metric = "Easy 5 km at 6:10 per km."

        #expect(CoachProseUnits.localized(imperial, to: .imperial) == imperial)
        #expect(CoachProseUnits.localized(metric, to: .metric) == metric)
    }

    @Test("Miles are rewritten in kilometres for a runner who uses kilometres")
    func milesToKilometres() {
        let note = "Easy 3.1 mi at 10:44 per mile, then 2 miles of strides."

        #expect(CoachProseUnits.localized(note, to: .metric) == "Easy 5.0 km at 6:40 per km, then 3.2 km of strides.")
    }

    @Test("Numbers that are not a pace or a distance are left as written")
    func leavesOtherNumbersAlone() {
        let note = "The fourth kilometre was quick, so race the 5K in 36 min and keep 2 minutes in hand."

        #expect(CoachProseUnits.localized(note, to: .imperial) == note)
    }

    @Test("The minutes of a pace are never read as a distance")
    func paceMinutesAreNotADistance() {
        // No "per": not a pace this recognises, and "40 km" inside "6:40 km" is not a distance.
        let note = "Hold 6:40 km splits."

        #expect(CoachProseUnits.localized(note, to: .imperial) == note)
    }
}
