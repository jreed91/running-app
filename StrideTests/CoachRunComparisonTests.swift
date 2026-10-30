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
        #expect(line?.contains("close enough") == false)
    }

    @Test("A small miss of the range counts as close to plan")
    func planCloseToRange() {
        let line = CoachRunComparison.planLine(
            actualPaceSecondsPerKm: 300,
            actualDistanceMeters: 0,
            targetPaceLower: 305,
            targetPaceUpper: 320,
            targetDistanceMeters: nil,
            unit: .metric
        )

        #expect(line == "Pace 5:00 min/km, 5 seconds faster than the planned 5:05–5:20 min/km, close enough to count as on plan.")
    }

    @Test("Seven seconds per mile quicker than a tempo range is close to plan")
    func planCloseToRangeImperial() {
        // The run from the bug report: 8:48 per mile against 8:55–9:11.
        let line = CoachRunComparison.planLine(
            actualPaceSecondsPerKm: 528 / 1.60934,
            actualDistanceMeters: 0,
            targetPaceLower: 535 / 1.60934,
            targetPaceUpper: 551 / 1.60934,
            targetDistanceMeters: nil,
            unit: .imperial
        )

        #expect(line?.contains("7 seconds faster than the planned") == true)
        #expect(line?.hasSuffix(", close enough to count as on plan.") == true)
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

    @Test("Long runs and races are not called \"long run runs\"")
    func baselineLineNamesRuns() {
        func line(_ typeName: String) -> String {
            CoachRunComparison.baselineLine(
                typeName: typeName,
                currentPaceSecondsPerKm: 300,
                currentHeartRate: nil,
                baseline: nil,
                unit: .metric
            )
        }

        #expect(line("Long Run").hasPrefix("Fewer than 3 recent long runs,"))
        #expect(line("Race").hasPrefix("Fewer than 3 recent races,"))
        #expect(line("Interval").hasPrefix("Fewer than 3 recent interval runs,"))
    }

    // MARK: What the planned pace is for

    private func segment(_ meters: Double?, _ label: String) -> WorkoutSegment {
        WorkoutSegment(distanceMeters: meters, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: label)
    }

    private func tempo(warmup: Double?, block: Double?, cooldown: Double?, reps: Int = 1) -> WorkoutStructure {
        WorkoutStructure(
            warmup: segment(warmup, "Warm-up"),
            mainSets: [
                WorkoutSet(
                    repetitions: reps,
                    workSegment: segment(block, "Tempo"),
                    recoverySegment: segment(nil, "Recovery jog"),
                    label: "Tempo Block"
                )
            ],
            cooldown: segment(cooldown, "Cool-down"),
            totalEstimatedDistanceMeters: (warmup ?? 0) + (block ?? 0) * Double(reps) + (cooldown ?? 0),
            totalEstimatedDurationSeconds: 3_000
        )
    }

    private func scope(
        _ type: WorkoutType,
        _ structure: WorkoutStructure?,
        intervals: [WorkoutInterval] = []
    ) -> CoachRunComparison.PlannedPaceScope {
        CoachRunComparison.plannedPaceScope(type: type, structure: structure, intervals: intervals)
    }

    @Test("An easy or long run's pace is for the whole run, an interval session's for the reps")
    func paceScopeByType() {
        #expect(scope(.easy, nil) == .wholeRun)
        #expect(scope(.longRun, tempo(warmup: 2_000, block: 10_000, cooldown: 2_000)) == .wholeRun)
        #expect(scope(.race, nil) == .wholeRun)
        #expect(scope(.interval, nil) == .workOnly(continuousMeters: nil))
    }

    @Test("A tempo between a warm-up and a cool-down is a block of known length")
    func paceScopeTempoBlock() {
        #expect(scope(.tempo, tempo(warmup: 2_000, block: 5_000, cooldown: 1_500)) == .workOnly(continuousMeters: 5_000))
        // A warm-up alone is enough to take the average off the tempo pace.
        #expect(scope(.tempo, tempo(warmup: 2_000, block: 5_000, cooldown: nil)) == .workOnly(continuousMeters: 5_000))
    }

    @Test("A tempo with nothing around it is held to its pace for the whole run")
    func paceScopeBareTempo() {
        #expect(scope(.tempo, nil) == .wholeRun)
        #expect(scope(.tempo, tempo(warmup: 0, block: 6_000, cooldown: nil)) == .wholeRun)
    }

    @Test("Tempo reps, or a block of unknown length, leave no block to find")
    func paceScopeTempoWithoutABlock() {
        #expect(scope(.tempo, tempo(warmup: 2_000, block: 1_600, cooldown: 1_000, reps: 3)) == .workOnly(continuousMeters: nil))
        #expect(scope(.tempo, tempo(warmup: 2_000, block: nil, cooldown: 1_000)) == .workOnly(continuousMeters: nil))
        let reps = WorkoutInterval(
            repetitions: 2,
            distanceMeters: 3_000,
            durationSeconds: nil,
            targetPaceSecondsPerKm: 290,
            recoverySeconds: 90,
            recoveryType: .jog
        )
        #expect(scope(.tempo, nil, intervals: [reps]) == .workOnly(continuousMeters: nil))
    }

    // MARK: Block pace

    private func splits(_ paces: [Double]) -> [Split] {
        paces.enumerated().map { index, pace in
            Split(
                kilometer: index + 1,
                paceSecondsPerKm: pace,
                heartRate: nil,
                elevationGainMeters: 0,
                cumulativeDistanceMeters: Double(index + 1) * 1_000
            )
        }
    }

    @Test("The block's pace is the fastest run of whole splits that fits inside it")
    func blockPaceFindsTheBlock() {
        // 2 km warm-up, 5 km tempo at 4:50, 2 km cool-down.
        let aligned = splits([360, 360, 290, 290, 290, 290, 290, 360, 360])
        #expect(CoachRunComparison.blockPace(splits: aligned, blockMeters: 5_000, splitMeters: 1_000)
            == CoachRunComparison.BlockPace(paceSecondsPerKm: 290, meters: 4_000))

        // The same session with a 2.4 km warm-up: the block starts and ends mid-split, and
        // the window of four still sits wholly inside it.
        let offset = splits([360, 360, 318, 290, 290, 290, 290, 329, 355])
        #expect(CoachRunComparison.blockPace(splits: offset, blockMeters: 5_000, splitMeters: 1_000)
            == CoachRunComparison.BlockPace(paceSecondsPerKm: 290, meters: 4_000))
    }

    @Test("No block pace when the block cannot hold a whole split, or nothing is left around it")
    func blockPaceNeedsRoom() {
        let run = splits([360, 360, 290, 290, 360, 360])
        #expect(CoachRunComparison.blockPace(splits: run, blockMeters: 1_500, splitMeters: 1_000) == nil)
        #expect(CoachRunComparison.blockPace(splits: splits([290, 290, 290, 290]), blockMeters: 5_000, splitMeters: 1_000) == nil)
        #expect(CoachRunComparison.blockPace(for: .wholeRun, splits: run, splitMeters: 1_000) == nil)
        #expect(CoachRunComparison.blockPace(for: .workOnly(continuousMeters: nil), splits: run, splitMeters: 1_000) == nil)
    }

    @Test("A tempo run to plan is judged on its block, not on the whole run's average")
    func planLineForATempoBlock() {
        // Its average, 5:21 per km, used to read "26 seconds slower than the planned".
        let line = CoachRunComparison.planLine(
            actualPaceSecondsPerKm: (4 * 360 + 5 * 290) / 9,
            actualDistanceMeters: 9_000,
            targetPaceLower: 285,
            targetPaceUpper: 295,
            targetDistanceMeters: 9_000,
            unit: .metric,
            paceScope: .workOnly(continuousMeters: 5_000),
            blockPace: CoachRunComparison.BlockPace(paceSecondsPerKm: 290, meters: 4_000)
        )

        #expect(line == "The planned pace is for the block between the warm-up and the cool-down. "
            + "The fastest 4.0 km of splits ran 4:50 min/km, inside the planned 4:45–4:55 min/km. "
            + "The whole run's average pace also takes in the warm-up and the cool-down, so it is "
            + "not the pace to judge. Distance 9.0 km of 9.0 km planned (100%).")
    }

    @Test("Without a block to read, the line says the average cannot judge the work")
    func planLineForReps() {
        let line = CoachRunComparison.planLine(
            actualPaceSecondsPerKm: 330,
            actualDistanceMeters: 0,
            targetPaceLower: 240,
            targetPaceUpper: 250,
            targetDistanceMeters: nil,
            unit: .metric,
            paceScope: .workOnly(continuousMeters: nil)
        )

        #expect(line == "The planned 4:00–4:10 min/km is the pace for the work, not the whole run. "
            + "The whole run's average pace also takes in the easy running around the work, so it "
            + "cannot show whether the work was on pace.")
        #expect(line?.contains("seconds slower") == false)
    }
}
