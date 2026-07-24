import Testing
import Foundation
@testable import Stride

/// Covers the turnaround-point maths behind out-and-back route generation.
///
/// The turnaround used to be placed at exactly half the requested distance as the
/// crow flies, so the routed leg — which has to follow roads — always came back
/// longer, and the finished out-and-back overshot what the runner asked for.
struct OutAndBackDistanceTests {

    @Test("The first turnaround guess is shortened to allow for road detours")
    func initialOffsetAccountsForDetour() {
        let offset = RouteGeniusService.initialTurnaroundOffsetMeters(targetTotalMeters: 10_000)

        // Half of 10 km is 5 km as the crow flies; the guess must be shorter than that.
        #expect(offset < 5_000)
        #expect(offset == 5_000 / RouteGeniusService.assumedDetourFactor)
    }

    @Test("A zero or negative request does not produce a negative offset")
    func initialOffsetClampsAtZero() {
        #expect(RouteGeniusService.initialTurnaroundOffsetMeters(targetTotalMeters: 0) == 0)
        #expect(RouteGeniusService.initialTurnaroundOffsetMeters(targetTotalMeters: -5_000) == 0)
    }

    @Test("An overshooting leg pulls the turnaround closer")
    func refinementShortensOnOvershoot() {
        let refined = RouteGeniusService.refinedTurnaroundOffsetMeters(
            previousOffsetMeters: 4_000,
            routedLegMeters: 6_000,
            targetLegMeters: 5_000
        )

        #expect(refined < 4_000)
        #expect(refined.isApproximately(4_000 * 5_000 / 6_000))
    }

    @Test("An undershooting leg pushes the turnaround further out")
    func refinementLengthensOnUndershoot() {
        let refined = RouteGeniusService.refinedTurnaroundOffsetMeters(
            previousOffsetMeters: 4_000,
            routedLegMeters: 3_000,
            targetLegMeters: 5_000
        )

        #expect(refined > 4_000)
        #expect(refined.isApproximately(4_000 * 5_000 / 3_000))
    }

    @Test("Correction is clamped so one bad response cannot fling the turnaround away")
    func refinementIsClamped() {
        let wayTooShort = RouteGeniusService.refinedTurnaroundOffsetMeters(
            previousOffsetMeters: 4_000,
            routedLegMeters: 10,
            targetLegMeters: 5_000
        )
        #expect(wayTooShort == 8_000)

        let wayTooLong = RouteGeniusService.refinedTurnaroundOffsetMeters(
            previousOffsetMeters: 4_000,
            routedLegMeters: 500_000,
            targetLegMeters: 5_000
        )
        #expect(wayTooLong == 2_000)
    }

    @Test("Degenerate inputs leave the offset untouched rather than producing NaN")
    func refinementRejectsDegenerateInput() {
        #expect(
            RouteGeniusService.refinedTurnaroundOffsetMeters(
                previousOffsetMeters: 4_000, routedLegMeters: 0, targetLegMeters: 5_000
            ) == 4_000
        )
        #expect(
            RouteGeniusService.refinedTurnaroundOffsetMeters(
                previousOffsetMeters: 0, routedLegMeters: 6_000, targetLegMeters: 5_000
            ) == 0
        )
        #expect(
            RouteGeniusService.refinedTurnaroundOffsetMeters(
                previousOffsetMeters: 4_000, routedLegMeters: 6_000, targetLegMeters: 0
            ) == 4_000
        )
    }

    @Test("A leg inside tolerance is accepted without spending another request")
    func toleranceAcceptsCloseEnoughLegs() {
        #expect(RouteGeniusService.isLegWithinTolerance(routedLegMeters: 5_200, targetLegMeters: 5_000))
        #expect(RouteGeniusService.isLegWithinTolerance(routedLegMeters: 4_800, targetLegMeters: 5_000))
        #expect(!RouteGeniusService.isLegWithinTolerance(routedLegMeters: 6_500, targetLegMeters: 5_000))
        #expect(!RouteGeniusService.isLegWithinTolerance(routedLegMeters: 3_000, targetLegMeters: 5_000))
    }
}

private extension Double {
    func isApproximately(_ other: Double, tolerance: Double = 0.000_001) -> Bool {
        abs(self - other) <= tolerance
    }
}
