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
}
