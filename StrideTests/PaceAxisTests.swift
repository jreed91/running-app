import Foundation
import Testing
@testable import Stride

/// Covers `PaceAxis`, the pace charts' axis ticks.
struct PaceAxisTests {

    private let mile = 1.60934

    @Test func milesLandOnWholeMinutes() {
        // 8:10 to 12:10 per mile, the spread in the screenshot that showed 8:02 and 9:23.
        let ticks = PaceAxis.ticks(
            lowerSecondsPerKm: 490 / mile, upperSecondsPerKm: 730 / mile, factor: mile
        )
        #expect(ticks.map { PaceAxis.label(secondsPerKm: $0, factor: mile) } == ["9:00", "10:00", "11:00", "12:00"])
    }

    @Test func narrowRangeUsesQuarterMinutes() {
        // 5:10 to 6:10 per km: whole and half minutes give too few ticks.
        let ticks = PaceAxis.ticks(lowerSecondsPerKm: 310, upperSecondsPerKm: 370, factor: 1)
        #expect(ticks.map { PaceAxis.label(secondsPerKm: $0, factor: 1) } == ["5:15", "5:30", "5:45", "6:00"])
    }

    @Test func wideRangeStaysUnderTheCap() {
        let ticks = PaceAxis.ticks(lowerSecondsPerKm: 240, upperSecondsPerKm: 900, factor: 1)
        #expect(ticks.count >= 2 && ticks.count <= 5)
        #expect(ticks.allSatisfy { Int($0.rounded()) % 60 == 0 })
    }

    @Test func singleValueStillGetsALabel() {
        let ticks = PaceAxis.ticks(lowerSecondsPerKm: 333, upperSecondsPerKm: 333, factor: 1)
        #expect(ticks.count == 1)
    }

    @Test func nonsenseGivesNoTicks() {
        #expect(PaceAxis.ticks(lowerSecondsPerKm: 0, upperSecondsPerKm: 300, factor: 1).isEmpty)
        #expect(PaceAxis.ticks(lowerSecondsPerKm: .nan, upperSecondsPerKm: 300, factor: 1).isEmpty)
    }

    @Test func labelRoundsRatherThanTruncates() {
        #expect(PaceAxis.label(secondsPerKm: 540 / mile, factor: mile) == "9:00")
    }
}
