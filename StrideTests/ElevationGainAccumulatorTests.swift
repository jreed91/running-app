import Foundation
import Testing
@testable import Stride

/// Climb counted through a dead band, so altitude jitter on the flat is not added up as
/// hills (P3).
struct ElevationGainAccumulatorTests {

    private func gain(_ altitudes: [Double]) -> Double {
        var climb = ElevationGainAccumulator()
        return altitudes.reduce(0) { $0 + climb.add($1) }
    }

    @Test("Jitter on flat ground adds no climb")
    func jitterIsIgnored() {
        // A metre either side of 100 m, which the old fix-to-fix sum counted as 8.9 m.
        let wobble: [Double] = [100, 101.2, 99.1, 100.8, 99.5, 101.4, 98.9, 100.6, 99.3, 101.1, 99.8, 100.4]
        #expect(gain(wobble) == 0)
    }

    @Test("A steady climb counts in full, less at most one band at the top")
    func steadyClimbCounts() {
        let hill = stride(from: 100.0, through: 160.0, by: 1).map { $0 }
        let counted = gain(hill)
        #expect(counted <= 60)
        #expect(counted > 60 - ElevationGainAccumulator.defaultThresholdMeters)
    }

    @Test("Down then up again counts the second climb from the bottom")
    func valleyResetsTheLevel() {
        // Up 10, down 10, up 10: 20 m of real climb.
        #expect(gain([100, 105, 110, 105, 100, 105, 110]) == 20)
    }

    @Test("Altitudes Core Location marks invalid or too vague are left out")
    func unusableAltitudes() {
        #expect(ElevationGainAccumulator.usableAltitude(120, verticalAccuracy: 4) == 120)
        #expect(ElevationGainAccumulator.usableAltitude(120, verticalAccuracy: -1) == nil)
        #expect(ElevationGainAccumulator.usableAltitude(120, verticalAccuracy: 40) == nil)
        #expect(ElevationGainAccumulator.usableAltitude(.nan, verticalAccuracy: 4) == nil)
    }
}
