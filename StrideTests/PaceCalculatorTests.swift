import Testing
@testable import Stride

// MARK: - VDOT / pace calculation tests

struct PaceCalculatorTests {

    // MARK: VDOT derivation

    @Test("VDOT from 20:00 5K is approximately 50")
    func vdotFrom20Min5K() {
        let vdot = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: 20 * 60)
        #expect((48...51).contains(Int(vdot)), "Expected ~50, got \(vdot)")
    }

    @Test("VDOT from 25:00 5K is approximately 38")
    func vdotFrom25Min5K() {
        let vdot = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: 25 * 60)
        #expect((37...40).contains(Int(vdot)), "Expected ~38, got \(vdot)")
    }

    @Test("VDOT increases as race time decreases")
    func vdotMonotonicity() {
        let faster = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: 20 * 60)
        let slower = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: 30 * 60)
        #expect(faster > slower)
    }

    @Test("VDOT returns 0 (not NaN/∞) for degenerate input")
    func vdotDegenerateInput() {
        // Zero or negative time/distance must not produce ∞/NaN, which would break
        // callers that guard on `v > 0` and comparators that sort runs by VDOT.
        let zeroTime = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: 0)
        let zeroDistance = PaceCalculatorService.vdot(distanceMeters: 0, timeSeconds: 20 * 60)
        let negativeTime = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: -60)
        #expect(zeroTime == 0)
        #expect(zeroDistance == 0)
        #expect(negativeTime == 0)
        #expect(zeroTime.isFinite && zeroDistance.isFinite && negativeTime.isFinite)
    }

    // MARK: Training paces ordering

    @Test("Interval pace is faster than tempo pace")
    func pacesOrdering() {
        let paces = PaceCalculatorService.trainingPaces(from5KTimeSeconds: 25 * 60)
        // Lower seconds/km = faster
        #expect(paces.interval < paces.threshold)
        #expect(paces.threshold < paces.marathon)
        #expect(paces.marathon < paces.easyRange.upperBound)
    }

    @Test("Easy range lower bound is faster than upper bound")
    func easyRangeDirection() {
        let paces = PaceCalculatorService.trainingPaces(from5KTimeSeconds: 25 * 60)
        #expect(paces.easyRange.lowerBound < paces.easyRange.upperBound)
    }

    // MARK: Race prediction round-trip

    @Test("Predicted 5K time from VDOT is close to the input time")
    func roundTrip5K() {
        let inputSeconds = 25.0 * 60   // 25:00
        let vdot = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: inputSeconds)
        let predicted = PaceCalculatorService.predictedTime(vdot: vdot, distanceMeters: 5_000)
        let delta = abs(predicted - inputSeconds)
        #expect(delta < 5, "Round-trip error: \(delta) seconds")
    }

    @Test("Half marathon predicted time is longer than 5K predicted time")
    func halfVsFiveK() {
        let vdot = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: 25 * 60)
        let fiveKTime = PaceCalculatorService.predictedTime(vdot: vdot, distanceMeters: 5_000)
        let halfTime = PaceCalculatorService.predictedTime(vdot: vdot, distanceMeters: 21_097.5)
        #expect(halfTime > fiveKTime)
    }

    // MARK: Daniels-table agreement (H2.2 — no double-discount of %VO₂max)

    /// Training paces are Daniels' %VO₂max zones, so they must land near the published
    /// tables. The pre-fix implementation multiplied intensity by `fractionVO2max` a
    /// second time, prescribing paces ~15–50 s/km too slow (e.g. threshold 4:36/km
    /// instead of ~4:15/km for VDOT 50). Each bound below excludes the old value.
    @Test("VDOT 50 training paces match the Daniels tables within tolerance")
    func vdot50PacesMatchDaniels() {
        // VDOT from an exact 19:57 5K ≈ 50.
        let paces = PaceCalculatorService.trainingPaces(forVDOT: 50)

        // Threshold ≈ 4:15/km (255 s). Old (broken) value ≈ 276 s.
        #expect((248...268).contains(paces.threshold),
                "Threshold \(paces.threshold)s/km outside Daniels tolerance")
        // Marathon ≈ 4:31/km (271 s). Old (broken) value ≈ 327 s.
        #expect((262...292).contains(paces.marathon),
                "Marathon \(paces.marathon)s/km outside Daniels tolerance")
        // Interval ≈ 3:57/km (237 s). Old (broken) value ≈ 268 s.
        #expect((224...250).contains(paces.interval),
                "Interval \(paces.interval)s/km outside Daniels tolerance")
        // Easy runs sit around 4:40–5:20/km (280–320 s) at VDOT 50.
        #expect(paces.easyRange.lowerBound > paces.threshold,
                "Easy pace should be slower (larger sec/km) than threshold")
    }

    @Test("Threshold pace is faster than marathon pace for the same VDOT")
    func thresholdFasterThanMarathon() {
        let paces = PaceCalculatorService.trainingPaces(forVDOT: 45)
        #expect(paces.threshold < paces.marathon)
        #expect(paces.marathon < paces.easyRange.lowerBound)
    }
}
