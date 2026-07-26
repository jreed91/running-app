import Testing
import Foundation
@testable import Stride

// MARK: - Spoken split announcements (U4)
//
// The run HUD gained haptics in the first UX pass, which can say "a split closed" but
// not what the split was. These cover the wording and, more importantly, the pace
// verdict: a runner acts on "8 seconds slow", so the sign and the unit have to be right.

struct SplitAnnouncementTests {

    // A 4:20–4:40/km target band, in the seconds-per-km the app works in internally.
    private let band: ClosedRange<Double> = 260...280

    @Test("A free run's split says the milestone and the pace, with no verdict")
    func freeRunSplit() {
        let phrase = SplitAnnouncement.phrase(
            splitNumber: 3,
            paceSecondsPerKm: 272,
            unit: .metric
        )
        #expect(phrase == "Kilometre 3. 4:32 minutes per kilometre.")
    }

    @Test("An imperial runner hears miles, and a pace converted into them")
    func imperialSplit() {
        let phrase = SplitAnnouncement.phrase(
            splitNumber: 2,
            paceSecondsPerKm: 272,
            unit: .imperial
        )
        // 272 s/km ≈ 437 s/mi = 7:17.
        #expect(phrase == "Mile 2. 7:17 minutes per mile.")
    }

    @Test("A split inside the target band is on pace")
    func onPaceInsideBand() {
        #expect(SplitAnnouncement.verdict(paceSecondsPerKm: 270, target: band, unit: .metric) == .onPace)
        // Both edges, exactly.
        #expect(SplitAnnouncement.verdict(paceSecondsPerKm: 260, target: band, unit: .metric) == .onPace)
        #expect(SplitAnnouncement.verdict(paceSecondsPerKm: 280, target: band, unit: .metric) == .onPace)
    }

    @Test("Landing just outside the band is still on pace — the tolerance is measurement noise")
    func toleranceAbsorbsSmallMisses() {
        #expect(SplitAnnouncement.verdict(paceSecondsPerKm: 253, target: band, unit: .metric) == .onPace)
        #expect(SplitAnnouncement.verdict(paceSecondsPerKm: 287, target: band, unit: .metric) == .onPace)
    }

    @Test("A quicker pace is a smaller number, and reads as fast")
    func fasterThanBand() {
        // 240 s/km is 20 s/km under the band's fast edge.
        #expect(SplitAnnouncement.verdict(paceSecondsPerKm: 240, target: band, unit: .metric) == .fast(bySeconds: 20))
        let phrase = SplitAnnouncement.phrase(
            splitNumber: 1,
            paceSecondsPerKm: 240,
            unit: .metric,
            targetPaceSecondsPerKm: band
        )
        #expect(phrase == "Kilometre 1. 4:00 minutes per kilometre. 20 seconds fast.")
    }

    @Test("A slower pace reads as slow, measured from the band's slow edge")
    func slowerThanBand() {
        #expect(SplitAnnouncement.verdict(paceSecondsPerKm: 300, target: band, unit: .metric) == .slow(bySeconds: 20))
        let phrase = SplitAnnouncement.phrase(
            splitNumber: 6,
            paceSecondsPerKm: 300,
            unit: .metric,
            targetPaceSecondsPerKm: band
        )
        #expect(phrase == "Kilometre 6. 5:00 minutes per kilometre. 20 seconds slow.")
    }

    @Test("An imperial delta is spoken in seconds per mile, not per kilometre")
    func deltaFollowsTheDisplayUnit() {
        // 20 s/km over the slow edge is ~32 s/mi over it, which is the number an
        // imperial runner would get by differencing the paces they can see.
        let verdict = SplitAnnouncement.verdict(paceSecondsPerKm: 300, target: band, unit: .imperial)
        #expect(verdict == .slow(bySeconds: 32))
    }

    @Test("A guided step's single target pace becomes a band by the tolerance")
    func singleTargetPaceGetsATolerance() {
        let target = 270.0...270.0
        #expect(SplitAnnouncement.verdict(paceSecondsPerKm: 276, target: target, unit: .metric) == .onPace)
        #expect(SplitAnnouncement.verdict(paceSecondsPerKm: 290, target: target, unit: .metric) == .slow(bySeconds: 20))
    }

    @Test("An unusable pace drops its clause instead of speaking dashes")
    func unusablePaceKeepsTheMilestone() {
        #expect(SplitAnnouncement.phrase(splitNumber: 4, paceSecondsPerKm: 0, unit: .metric) == "Kilometre 4.")
        #expect(SplitAnnouncement.phrase(splitNumber: 4, paceSecondsPerKm: .infinity, unit: .metric) == "Kilometre 4.")
        #expect(SplitAnnouncement.verdict(paceSecondsPerKm: 0, target: band, unit: .metric) == nil)
    }

    @Test("There is no split zero")
    func nonPositiveSplitNumberIsNotAnnounced() {
        #expect(SplitAnnouncement.phrase(splitNumber: 0, paceSecondsPerKm: 270, unit: .metric) == nil)
    }
}
