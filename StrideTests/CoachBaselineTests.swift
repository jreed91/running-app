import Foundation
import Testing
@testable import Stride

/// Covers `CoachBaseline`, the global-until-personal threshold policy.
///
/// The switch point is the whole design, so both sides of it are pinned here — including
/// the case the policy exists for: a reading that is unremarkable against the published
/// figure but a real departure from this runner's own.
struct CoachBaselineTests {

    private func resolve(_ samples: [Double], global: Double = 165, drop: Double = 6) -> CoachBaseline.Resolved {
        CoachBaseline.resolve(samples: samples, global: global) { $0 - drop }
    }

    // MARK: - The switch

    @Test("Thin history keeps the published figure")
    func thinHistoryUsesGlobal() {
        let resolved = resolve(Array(repeating: 180, count: CoachBaseline.sampleFloor - 1))
        #expect(!resolved.isPersonal)
        #expect(resolved.value == 165)
    }

    @Test("Enough history switches to the runner's own")
    func enoughHistorySwitches() {
        let resolved = resolve(Array(repeating: 180, count: CoachBaseline.sampleFloor))
        #expect(resolved.isPersonal)
        #expect(resolved.value == 174)
        #expect(resolved.sampleCount == CoachBaseline.sampleFloor)
    }

    @Test("No history at all keeps the published figure and reports no samples")
    func noHistory() {
        let resolved = resolve([])
        #expect(!resolved.isPersonal)
        #expect(resolved.value == 165)
        #expect(resolved.sampleCount == 0)
    }

    @Test("Unusable readings do not count toward the switch")
    func unusableSamplesAreDropped() {
        // Eight entries, but only three of them are readings.
        let resolved = resolve([180, 0, -1, .nan, 178, .infinity, 0, 176])
        #expect(!resolved.isPersonal)
        #expect(resolved.sampleCount == 3)
    }

    // MARK: - The median

    @Test("The median ignores an outlier a mean would follow")
    func medianResistsOutliers() {
        // Eight ordinary readings and one race effort far outside them.
        let samples: [Double] = [176, 175, 177, 176, 178, 175, 177, 176, 240]
        let resolved = resolve(samples)
        #expect(resolved.isPersonal)
        // Median 176, less the six-point drop.
        #expect(resolved.value == 170)
    }

    @Test("An even count averages the two middle readings")
    func evenCountAveragesTheMiddle() {
        #expect(CoachBaseline.median(of: [1, 2, 3, 4]) == 2.5)
        #expect(CoachBaseline.median(of: [4, 1, 3, 2]) == 2.5)
    }

    @Test("An odd count takes the middle reading")
    func oddCountTakesTheMiddle() {
        #expect(CoachBaseline.median(of: [5, 1, 3]) == 3)
    }

    @Test("An empty set has no median")
    func emptyHasNoMedian() {
        #expect(CoachBaseline.median(of: []) == nil)
    }

    // MARK: - What the policy is for

    @Test("A runner who has always turned over slowly gets a threshold below their normal")
    func slowButConsistentRunnerIsNotFlagged() {
        let resolved = resolve(Array(repeating: 156, count: 12))
        // Their own 156, less the drop — so running at 156 is not a departure.
        #expect(resolved.value == 150)
        #expect(156 > resolved.value)
    }

    @Test("A quick runner's threshold sits above the published figure")
    func quickRunnerGetsAHigherBar() {
        let resolved = resolve(Array(repeating: 182, count: 12))
        #expect(resolved.value == 176)
        // 168 is above the published 165 and still a real drop for this runner.
        #expect(168 < resolved.value)
    }

    // MARK: - Derivation

    @Test("A personalised threshold can say where it came from; a global one cannot")
    func derivationFragment() {
        let personal = resolve(Array(repeating: 180, count: 10))
        #expect(personal.derivationFragment?.contains("10") == true)

        let global = resolve([180, 180])
        #expect(global.derivationFragment == nil)
    }
}
