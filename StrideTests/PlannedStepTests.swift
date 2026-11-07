import Testing
import Foundation
@testable import Stride

/// The planned workout screen's Steps card (`PlannedStep`) and the easy-run structure
/// behind it.
struct PlannedStepTests {

    private func segment(
        _ label: String, meters: Double? = nil, seconds: Double? = nil, pace: Double? = nil
    ) -> WorkoutSegment {
        WorkoutSegment(distanceMeters: meters, durationSeconds: seconds, targetPaceSecondsPerKm: pace, label: label)
    }

    @Test("An easy run reads warm-up, run, cool-down with short paces")
    func easyRunSteps() {
        let structure = WorkoutStructure(
            warmup: segment("Warm-up", meters: 500, pace: 420),
            mainSets: [WorkoutSet(
                repetitions: 1,
                workSegment: segment("Easy run", meters: 4_000, pace: 400),
                recoverySegment: segment(""),
                label: "Easy Run"
            )],
            cooldown: segment("Cool-down", meters: 500, pace: 420),
            totalEstimatedDistanceMeters: 5_000,
            totalEstimatedDurationSeconds: 2_000
        )

        let steps = PlannedStep.steps(from: structure, unit: .metric)

        #expect(steps.map(\.title) == ["Warm-up", "Easy Run", "Cool-down"])
        #expect(steps.map(\.amount) == ["500 m", "4.0 km", "500 m"])
        #expect(steps.map(\.pace) == ["7:00 /km", "6:40 /km", "7:00 /km"])
        #expect(steps.map(\.isWork) == [false, true, false])
        // A single rep has nothing to recover between.
        #expect(steps[1].note == nil)
    }

    @Test("Repeats show the count with the distance and the recovery between")
    func intervalSteps() {
        let structure = WorkoutStructure(
            warmup: segment("Warm-up", meters: 1_000, pace: 400),
            mainSets: [WorkoutSet(
                repetitions: 5,
                workSegment: segment("Interval", meters: 800, pace: 240),
                recoverySegment: segment("Recovery jog", seconds: 90),
                label: "VO2max Intervals"
            )],
            cooldown: segment("Cool-down", meters: 1_000, pace: 400),
            totalEstimatedDistanceMeters: 6_000,
            totalEstimatedDurationSeconds: 2_400
        )

        let main = PlannedStep.steps(from: structure, unit: .metric)[1]

        #expect(main.title == "VO2max Intervals")
        #expect(main.amount == "5 × 800 m")
        #expect(main.pace == "4:00 /km")
        #expect(main.note == "1:30 recovery jog between")
    }

    @Test("Blank placeholder segments are left out")
    func blankSegmentsSkipped() {
        let structure = WorkoutStructure(
            warmup: segment(""),
            mainSets: [WorkoutSet(
                repetitions: 1,
                workSegment: segment("Walk-run", seconds: 1_800),
                recoverySegment: segment(""),
                label: ""
            )],
            cooldown: segment(""),
            totalEstimatedDistanceMeters: 0,
            totalEstimatedDurationSeconds: 1_800
        )

        let steps = PlannedStep.steps(from: structure, unit: .metric)

        #expect(steps.count == 1)
        #expect(steps.first?.title == "Walk-run")
        #expect(steps.first?.amount == "30:00")
    }

    @Test("Imperial distances and paces use miles")
    func imperialUnits() {
        #expect(PlannedStep.distanceText(500, unit: .imperial) == "0.3 mi")
        #expect(PlannedStep.paceText(400, unit: .imperial) == "10:43 /mi")
    }

    @Test("An adapted easy run cools down at the slow end of the band, like its warm-up")
    func easyCooldownIsNotTheFastEnd() throws {
        let profile = UserProfile(
            name: "Test Runner",
            goalRace: .fiveK,
            goalFinishTime: 20 * 60,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate,
            currentEstimated5KTimeSeconds: 25 * 60
        )
        let scheduled = ScheduledWorkout(scheduledDate: .now, workoutType: .easy, targetDistanceMeters: 5_000)

        let adapted = TrainingPlanService().adaptWorkout(scheduled: scheduled, history: [], profile: profile)
        let structure = try #require(adapted.workoutStructure)
        let warmupPace = try #require(structure.warmup.targetPaceSecondsPerKm)
        let cooldownPace = try #require(structure.cooldown.targetPaceSecondsPerKm)
        let mainPace = try #require(structure.mainSets.first?.workSegment.targetPaceSecondsPerKm)

        #expect(cooldownPace == warmupPace)
        // Seconds per km: a bigger number is slower.
        #expect(cooldownPace >= mainPace)
    }
}
