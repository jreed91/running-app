import Testing
import Foundation
@testable import Stride

// MARK: - HeartRateZoneService tests (A6)
//
// Covers zone classification, display bounds, and per-run/aggregate time-in-zone
// distribution used by the run-detail and Progress heart-rate-zone breakdowns.

struct HeartRateZoneServiceTests {

    private let maxHR = 200.0   // convenient: % of max == bpm / 2

    @Test("Readings classify into the right zone; sub-Z1 clamps to Z1")
    func classification() {
        #expect(HeartRateZoneService.zone(forBPM: 90, maxHR: maxHR) == .z1)   // 45% clamps up
        #expect(HeartRateZoneService.zone(forBPM: 110, maxHR: maxHR) == .z1)  // 55%
        #expect(HeartRateZoneService.zone(forBPM: 120, maxHR: maxHR) == .z2)  // 60%
        #expect(HeartRateZoneService.zone(forBPM: 139, maxHR: maxHR) == .z2)  // 69.5%
        #expect(HeartRateZoneService.zone(forBPM: 140, maxHR: maxHR) == .z3)  // 70%
        #expect(HeartRateZoneService.zone(forBPM: 160, maxHR: maxHR) == .z4)  // 80%
        #expect(HeartRateZoneService.zone(forBPM: 180, maxHR: maxHR) == .z5)  // 90%
        #expect(HeartRateZoneService.zone(forBPM: 205, maxHR: maxHR) == .z5)  // over max
    }

    @Test("Zero max HR never crashes and defaults to Z1")
    func zeroMaxHR() {
        #expect(HeartRateZoneService.zone(forBPM: 150, maxHR: 0) == .z1)
    }

    @Test("Display bounds are the zone's % window in bpm")
    func bounds() {
        let z3 = HeartRateZoneService.bounds(for: .z3, maxHR: maxHR)
        #expect(z3.lower == 140)
        #expect(z3.upper == 160)
        let z5 = HeartRateZoneService.bounds(for: .z5, maxHR: maxHR)
        #expect(z5.lower == 180)
        #expect(z5.upper == 200)
    }

    @Test("Time-in-zones distributes duration evenly across samples")
    func timeInZones() {
        // Two samples in Z3 (150 = 75%), two in Z5 (190 = 95%); 400 s total → 100 s each.
        let slices = HeartRateZoneService.timeInZones(
            bpmSamples: [150, 150, 190, 190], totalSeconds: 400, maxHR: maxHR
        )
        #expect(slices.count == HRZone.allCases.count)
        func seconds(_ z: HRZone) -> Double { slices.first { $0.zone == z }!.seconds }
        #expect(seconds(.z3) == 200)
        #expect(seconds(.z5) == 200)
        #expect(seconds(.z1) == 0)
        // All valid samples accounted for.
        #expect(slices.reduce(0) { $0 + $1.seconds } == 400)
    }

    @Test("Empty samples or zero duration yields all-zero slices (still one per zone)")
    func emptyInputs() {
        let noSamples = HeartRateZoneService.timeInZones(bpmSamples: [], totalSeconds: 600, maxHR: maxHR)
        #expect(noSamples.count == HRZone.allCases.count)
        #expect(noSamples.allSatisfy { $0.seconds == 0 })

        let zeroDuration = HeartRateZoneService.timeInZones(bpmSamples: [150], totalSeconds: 0, maxHR: maxHR)
        #expect(zeroDuration.allSatisfy { $0.seconds == 0 })
    }

    @Test("Aggregate merges multiple per-run distributions")
    func aggregate() {
        let run1 = HeartRateZoneService.timeInZones(bpmSamples: [150], totalSeconds: 300, maxHR: maxHR) // Z3 300
        let run2 = HeartRateZoneService.timeInZones(bpmSamples: [150], totalSeconds: 200, maxHR: maxHR) // Z3 200
        let merged = HeartRateZoneService.aggregate([run1, run2])
        #expect(merged.first { $0.zone == .z3 }!.seconds == 500)
        #expect(merged.count == HRZone.allCases.count)
    }
}

// MARK: - UserProfile max-HR helpers

struct UserProfileHeartRateTests {

    private func makeProfile() -> UserProfile {
        UserProfile(name: "Test", goalRace: .fiveK, goalFinishTime: 1_500, weeklyRunDays: 3, fitnessLevel: .intermediate)
    }

    @Test("Tanaka estimate is 208 − 0.7 × age")
    func tanaka() {
        #expect(UserProfile.estimatedMaxHeartRate(forAge: 30) == 187)  // 208 − 21
        #expect(UserProfile.estimatedMaxHeartRate(forAge: 40) == 180)  // 208 − 28
    }

    @Test("Effective max HR: explicit value wins over age estimate")
    func explicitWins() {
        let p = makeProfile()
        p.age = 40
        p.maxHeartRateBPM = 195
        #expect(p.effectiveMaxHeartRate == 195)
    }

    @Test("Effective max HR falls back to the age estimate, then nil")
    func fallbacks() {
        let p = makeProfile()
        #expect(p.effectiveMaxHeartRate == nil)       // nothing set
        p.age = 30
        #expect(p.effectiveMaxHeartRate == 187)        // age estimate
    }
}
