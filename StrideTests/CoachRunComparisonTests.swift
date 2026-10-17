import Testing
import Foundation
@testable import Stride

struct CoachRunComparisonTests {

    // MARK: Plan

    @Test("A pace inside the planned range says so, with the distance against plan")
    func planInsideRange() {
        let line = CoachRunComparison.planLine(
            actualPaceSecondsPerKm: 312,
            actualDistanceMeters: 8_100,
            targetPaceLower: 305,
            targetPaceUpper: 320,
            targetDistanceMeters: 8_000,
            unit: .metric
        )

        #expect(line == "Pace 5:12 min/km, inside the planned 5:05–5:20 min/km. Distance 8.1 km of 8.0 km planned (101%).")
    }

    @Test("A pace faster than the range names the gap to the fast end")
    func planFasterThanRange() {
        let line = CoachRunComparison.planLine(
            actualPaceSecondsPerKm: 290,
            actualDistanceMeters: 0,
            targetPaceLower: 305,
            targetPaceUpper: 320,
            targetDistanceMeters: nil,
            unit: .metric
        )

        #expect(line == "Pace 4:50 min/km, 15 seconds faster than the planned 5:05–5:20 min/km.")
    }

    @Test("A pace slower than the range names the gap to the slow end")
    func planSlowerThanRange() {
        let line = CoachRunComparison.planLine(
            actualPaceSecondsPerKm: 330,
            actualDistanceMeters: 0,
            targetPaceLower: 305,
            targetPaceUpper: 320,
            targetDistanceMeters: nil,
            unit: .metric
        )

        #expect(line?.hasPrefix("Pace 5:30 min/km, 10 seconds slower than the planned") == true)
    }

    @Test("Within the tolerance of an edge still counts as on target")
    func planToleranceAtEdge() {
        let line = CoachRunComparison.planLine(
            actualPaceSecondsPerKm: 322,
            actualDistanceMeters: 0,
            targetPaceLower: 305,
            targetPaceUpper: 320,
            targetDistanceMeters: nil,
            unit: .metric
        )

        #expect(line?.contains("inside the planned") == true)
    }

    @Test("A plan with no targets gives no line")
    func planWithoutTargets() {
        let line = CoachRunComparison.planLine(
            actualPaceSecondsPerKm: 312,
            actualDistanceMeters: 8_000,
            targetPaceLower: nil,
            targetPaceUpper: nil,
            targetDistanceMeters: nil,
            unit: .metric
        )

        #expect(line == nil)
    }

    // MARK: Baseline

    private func sample(_ pace: Double, hr: Double? = nil, distance: Double = 8_000) -> CoachRunComparison.Sample {
        CoachRunComparison.Sample(paceSecondsPerKm: pace, heartRate: hr, distanceMeters: distance)
    }

    @Test("Fewer runs than the floor give no baseline")
    func baselineNeedsFloor() {
        #expect(CoachRunComparison.baseline(from: [sample(360), sample(370)]) == nil)
    }

    @Test("The baseline averages pace, distance and heart rate")
    func baselineAverages() {
        let baseline = CoachRunComparison.baseline(from: [
            sample(360, hr: 140, distance: 6_000),
            sample(370, hr: 144, distance: 8_000),
            sample(365, hr: 142, distance: 10_000)
        ])

        #expect(baseline == CoachRunComparison.Baseline(
            runCount: 3,
            paceSecondsPerKm: 365,
            heartRate: 142,
            distanceMeters: 8_000
        ))
    }

    @Test("Heart rate drops out of the baseline when too few runs recorded it")
    func baselineWithoutEnoughHeartRate() {
        let baseline = CoachRunComparison.baseline(from: [
            sample(360, hr: 140),
            sample(370),
            sample(365)
        ])

        #expect(baseline?.heartRate == nil)
    }

    @Test("The baseline line compares pace and heart rate with the usual")
    func baselineLineCompares() {
        let baseline = CoachRunComparison.Baseline(
            runCount: 5,
            paceSecondsPerKm: 365,
            heartRate: 146,
            distanceMeters: 7_200
        )

        let line = CoachRunComparison.baselineLine(
            typeName: "Easy",
            currentPaceSecondsPerKm: 356,
            currentHeartRate: 142,
            baseline: baseline,
            unit: .metric
        )

        #expect(line == "Your last 5 easy runs averaged 6:05 min/km at 146 bpm over 7.2 km. This one: 9 seconds faster per km, 4 bpm lower.")
    }

    @Test("Without a baseline the line says there is no usual yet")
    func baselineLineWithoutBaseline() {
        let line = CoachRunComparison.baselineLine(
            typeName: "Tempo",
            currentPaceSecondsPerKm: 300,
            currentHeartRate: nil,
            baseline: nil,
            unit: .metric
        )

        #expect(line == "Fewer than 3 recent tempo runs, so there is no usual to compare with.")
    }
}
