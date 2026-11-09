import Testing
@testable import Stride

struct RunVolumeSharesTests {

    @Test("Three run days: the easy run is held under the long run and the week schedules less")
    func threeDays() {
        let shares = RunVolumeShares(runDays: 3, qualitySlots: 1)
        #expect(shares.long == 0.35)
        #expect(abs(shares.easyEach - 0.28) < 1e-9)
        #expect(shares.easyEach < shares.long)
        #expect(abs(shares.scheduledFraction - 0.78) < 1e-9)
    }

    @Test("One and two run days fold the remainder into the long run (M32)", arguments: [1, 2])
    func fewDays(runDays: Int) {
        let shares = RunVolumeShares(runDays: runDays, qualitySlots: 1)
        #expect(shares.easySlots == 0)
        #expect(abs(shares.scheduledFraction - 1) < 1e-9)
    }

    @Test("Five run days with two quality sessions are untouched by the cap")
    func fiveDays() {
        let shares = RunVolumeShares(runDays: 5, qualitySlots: 2)
        #expect(shares.easySlots == 2)
        #expect(abs(shares.easyEach - 0.175) < 1e-9)
        #expect(abs(shares.scheduledFraction - 1) < 1e-9)
    }

    @Test("Four run days with two quality sessions: the one easy run is capped too")
    func fourDaysTwoQuality() {
        let shares = RunVolumeShares(runDays: 4, qualitySlots: 2)
        #expect(shares.easySlots == 1)
        #expect(abs(shares.easyEach - 0.28) < 1e-9)
    }

    @Test("A capped long run caps the easy runs and the quality session under it")
    func longCap() {
        let shares = RunVolumeShares(runDays: 4, qualitySlots: 1, longCap: 0.2)
        #expect(shares.long == 0.2)
        #expect(abs(shares.easyEach - 0.16) < 1e-9)
        #expect(shares.qualityEach == 0.15)
        let tight = RunVolumeShares(runDays: 4, qualitySlots: 1, longCap: 0.1)
        #expect(tight.qualityEach == 0.1)
    }

    @Test("A cap on a one or two day week stops the remainder folding into the long run", arguments: [1, 2])
    func longCapFewDays(runDays: Int) {
        let shares = RunVolumeShares(runDays: runDays, qualitySlots: 1, longCap: 0.5)
        #expect(shares.long == 0.5)
        #expect(shares.scheduledFraction < 1)
    }
}
