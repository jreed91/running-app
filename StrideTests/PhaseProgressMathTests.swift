import CoreGraphics
import Testing
@testable import Stride

@Suite("PhaseProgressMath")
struct PhaseProgressMathTests {

    private func phases(base: Int, build: Int, peak: Int, taper: Int) -> [TrainingPhase] {
        Array(repeating: .base, count: base)
            + Array(repeating: .build, count: build)
            + Array(repeating: .peak, count: peak)
            + Array(repeating: .taper, count: taper)
    }

    @Test("No weeks produces no transition markers")
    func emptyProducesNothing() {
        #expect(PhaseProgressMath.transitionFractions(weekPhases: []).isEmpty)
    }

    @Test("A full four-phase plan yields three ascending markers")
    func fourPhasePlanYieldsThreeMarkers() {
        // 4 base, 3 build, 2 peak, 1 taper = 10 weeks.
        let fractions = PhaseProgressMath.transitionFractions(
            weekPhases: phases(base: 4, build: 3, peak: 2, taper: 1)
        )
        #expect(fractions == [0.4, 0.7, 0.9])
    }

    @Test("A zero-week phase does not emit a duplicate marker")
    func zeroWeekPhaseIsDeduped() {
        // Build has zero weeks: base=3, build=0, peak=2, taper=2 (7 weeks).
        // Base→Build and Build→Peak both land at 3/7; only one marker should remain.
        let fractions = PhaseProgressMath.transitionFractions(
            weekPhases: phases(base: 3, build: 0, peak: 2, taper: 2)
        )
        #expect(fractions == Array(Set(fractions)).sorted())
        #expect(Set(fractions).count == fractions.count, "Duplicate markers: \(fractions)")
    }

    @Test("A single-phase plan yields no interior markers")
    func singlePhaseHasNoInteriorMarkers() {
        // All base: every cumulative fraction is either 0 or 1 (exclusive-filtered out).
        let fractions = PhaseProgressMath.transitionFractions(
            weekPhases: phases(base: 6, build: 0, peak: 0, taper: 0)
        )
        #expect(fractions.isEmpty)
    }

    @Test("Markers stay strictly inside the 0–1 range")
    func markersAreInteriorFractions() {
        let fractions = PhaseProgressMath.transitionFractions(
            weekPhases: phases(base: 2, build: 2, peak: 2, taper: 2)
        )
        for fraction in fractions {
            #expect(fraction > 0 && fraction < 1)
        }
    }
}
