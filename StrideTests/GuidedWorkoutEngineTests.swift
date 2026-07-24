import Testing
import Foundation
@testable import Stride

// MARK: - Guided structured-workout execution tests (A4)
//
// Covers flattening a WorkoutStructure into an ordered step list, in-step
// progress, and the auto/manual advancement state machine. All pure — no
// tracker, HealthKit, or SwiftUI.

struct GuidedWorkoutEngineTests {

    // MARK: Fixtures

    /// An interval session: 1 km warm-up, `reps` × (800 m work @ 3:55/km + 90 s
    /// recovery jog), 1 km cool-down — the shape `TrainingPlanService` emits.
    private func intervalStructure(reps: Int = 3) -> WorkoutStructure {
        let warmup = WorkoutSegment(
            distanceMeters: 1_000, durationSeconds: nil,
            targetPaceSecondsPerKm: 360, label: "Warm-up"
        )
        let work = WorkoutSegment(
            distanceMeters: 800, durationSeconds: nil,
            targetPaceSecondsPerKm: 235, label: ""
        )
        let recovery = WorkoutSegment(
            distanceMeters: nil, durationSeconds: 90,
            targetPaceSecondsPerKm: nil, label: "Recovery jog"
        )
        let set = WorkoutSet(repetitions: reps, workSegment: work, recoverySegment: recovery, label: "VO2max Intervals")
        let cooldown = WorkoutSegment(
            distanceMeters: 1_000, durationSeconds: nil,
            targetPaceSecondsPerKm: 360, label: "Cool-down"
        )
        return WorkoutStructure(
            warmup: warmup, mainSets: [set], cooldown: cooldown,
            totalEstimatedDistanceMeters: 4_400, totalEstimatedDurationSeconds: 1_800
        )
    }

    /// A tempo session: warm-up, a single continuous tempo block whose recovery
    /// segment is empty, cool-down.
    private func tempoStructure() -> WorkoutStructure {
        let warmup = WorkoutSegment(distanceMeters: 500, durationSeconds: nil, targetPaceSecondsPerKm: 360, label: "Warm-up")
        let work = WorkoutSegment(distanceMeters: 4_000, durationSeconds: nil, targetPaceSecondsPerKm: 260, label: "Tempo")
        let emptyRecovery = WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: "")
        let set = WorkoutSet(repetitions: 1, workSegment: work, recoverySegment: emptyRecovery, label: "Tempo Block")
        let cooldown = WorkoutSegment(distanceMeters: 500, durationSeconds: nil, targetPaceSecondsPerKm: 360, label: "Cool-down")
        return WorkoutStructure(
            warmup: warmup, mainSets: [set], cooldown: cooldown,
            totalEstimatedDistanceMeters: 5_000, totalEstimatedDurationSeconds: 1_400
        )
    }

    // MARK: Flattening

    @Test("Interval flattens to warm-up + reps × (work + recovery) + cool-down")
    func flattenInterval() {
        let steps = GuidedWorkoutState.flatten(intervalStructure(reps: 3))
        // 1 warm-up + 3×(work+recovery) + 1 cool-down = 8
        #expect(steps.count == 8)
        #expect(steps.first?.kind == .warmup)
        #expect(steps.last?.kind == .cooldown)

        let kinds = steps.map(\.kind)
        #expect(kinds == [.warmup, .work, .recovery, .work, .recovery, .work, .recovery, .cooldown])

        // Rep indices are 1-based and paired with the total rep count.
        let workSteps = steps.filter { $0.kind == .work }
        #expect(workSteps.map(\.repIndex) == [1, 2, 3])
        #expect(workSteps.allSatisfy { $0.repCount == 3 })
    }

    @Test("Empty recovery segments (tempo) produce no recovery step")
    func flattenTempoOmitsEmptyRecovery() {
        let steps = GuidedWorkoutState.flatten(tempoStructure())
        #expect(steps.map(\.kind) == [.warmup, .work, .cooldown])
        // A single-rep set carries no rep index.
        #expect(steps[1].repIndex == nil)
        #expect(steps[1].label == "Tempo")
    }

    @Test("Segment targets prefer distance, then time, then open")
    func targetPrecedence() {
        let steps = GuidedWorkoutState.flatten(intervalStructure(reps: 1))
        #expect(steps[0].target == .distance(meters: 1_000))   // warm-up
        #expect(steps[1].target == .distance(meters: 800))     // work
        #expect(steps[2].target == .time(seconds: 90))         // recovery jog
    }

    @Test("Fallback labels fill in for empty segment labels")
    func fallbackLabels() {
        let steps = GuidedWorkoutState.flatten(intervalStructure(reps: 1))
        // Work segment label is empty -> falls back to the set label.
        #expect(steps[1].label == "VO2max Intervals")
    }

    // MARK: Init gating

    @Test("A structure with no work steps does not engage guided mode")
    func initReturnsNilWithoutWork() {
        let openSeg = WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: "")
        // Warm-up + cool-down only, no main sets -> no work step to guide.
        let shell = WorkoutStructure(
            warmup: openSeg, mainSets: [], cooldown: openSeg,
            totalEstimatedDistanceMeters: 0, totalEstimatedDurationSeconds: 0
        )
        #expect(GuidedWorkoutState(structure: shell) == nil)
    }

    @Test("Interval structure builds a valid engine positioned at step 1")
    func initInterval() {
        let state = GuidedWorkoutState(structure: intervalStructure(reps: 2))
        #expect(state != nil)
        #expect(state?.stepNumber == 1)
        #expect(state?.stepCount == 6)
        #expect(state?.currentStep.kind == .warmup)
        #expect(state?.isOnFinalStep == false)
        #expect(state?.nextStep?.kind == .work)
    }

    // MARK: Progress

    @Test("Distance-step progress is measured within the step and reports remaining")
    func distanceProgress() {
        let state = GuidedWorkoutState(structure: intervalStructure(reps: 1))!
        // Warm-up is 1 000 m, starting at cumulative 0.
        let prog = state.progress(cumulativeDistanceMeters: 400, cumulativeElapsedSeconds: 120)
        #expect(abs(prog.fraction - 0.4) < 0.0001)
        #expect(prog.isTargetReached == false)
        #expect(prog.remainingDistanceMeters == 600)
        #expect(prog.remainingSeconds == nil)
    }

    @Test("Time-step progress uses elapsed offset from when the step began")
    func timeProgressUsesOffset() {
        var state = GuidedWorkoutState(structure: intervalStructure(reps: 1))!
        // Advance past warm-up (1 000 m) then work (800 m) to reach recovery.
        state.advance(cumulativeDistanceMeters: 1_000, cumulativeElapsedSeconds: 360)
        state.advance(cumulativeDistanceMeters: 1_800, cumulativeElapsedSeconds: 550)
        #expect(state.currentStep.kind == .recovery)
        // Recovery is 90 s; 60 s into it (elapsed 610, offset 550).
        let prog = state.progress(cumulativeDistanceMeters: 1_850, cumulativeElapsedSeconds: 610)
        #expect(abs(prog.fraction - (60.0 / 90.0)) < 0.0001)
        #expect(prog.remainingSeconds == 30)
        #expect(prog.isTargetReached == false)
    }

    @Test("Open steps have indeterminate progress and never report a target reached")
    func openProgress() {
        let openWarmup = WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: "Warm-up")
        let work = WorkoutSegment(distanceMeters: 3_000, durationSeconds: nil, targetPaceSecondsPerKm: 260, label: "Work")
        let empty = WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: "")
        let structure = WorkoutStructure(
            warmup: openWarmup,
            mainSets: [WorkoutSet(repetitions: 1, workSegment: work, recoverySegment: empty, label: "Block")],
            cooldown: WorkoutSegment(distanceMeters: 500, durationSeconds: nil, targetPaceSecondsPerKm: 360, label: "Cool-down"),
            totalEstimatedDistanceMeters: 3_500, totalEstimatedDurationSeconds: 1_200
        )
        let state = GuidedWorkoutState(structure: structure)!
        #expect(state.currentStep.isOpen)
        let prog = state.progress(cumulativeDistanceMeters: 5_000, cumulativeElapsedSeconds: 9_999)
        #expect(prog.fraction == 0)
        #expect(prog.isTargetReached == false)
        #expect(state.shouldAutoAdvance(cumulativeDistanceMeters: 5_000, cumulativeElapsedSeconds: 9_999) == false)
    }

    // MARK: Auto-advance

    @Test("Auto-advance fires only once the in-step target is met")
    func autoAdvanceBoundaries() {
        var state = GuidedWorkoutState(structure: intervalStructure(reps: 2))!

        // Warm-up 1 000 m
        #expect(state.shouldAutoAdvance(cumulativeDistanceMeters: 999, cumulativeElapsedSeconds: 300) == false)
        #expect(state.shouldAutoAdvance(cumulativeDistanceMeters: 1_000, cumulativeElapsedSeconds: 300) == true)
        state.advance(cumulativeDistanceMeters: 1_000, cumulativeElapsedSeconds: 300)

        // Work 800 m (from cumulative 1 000)
        #expect(state.currentStep.kind == .work)
        #expect(state.shouldAutoAdvance(cumulativeDistanceMeters: 1_700, cumulativeElapsedSeconds: 480) == false)
        #expect(state.shouldAutoAdvance(cumulativeDistanceMeters: 1_800, cumulativeElapsedSeconds: 490) == true)
        state.advance(cumulativeDistanceMeters: 1_800, cumulativeElapsedSeconds: 490)

        // Recovery 90 s (from elapsed 490)
        #expect(state.currentStep.kind == .recovery)
        #expect(state.shouldAutoAdvance(cumulativeDistanceMeters: 1_850, cumulativeElapsedSeconds: 579) == false)
        #expect(state.shouldAutoAdvance(cumulativeDistanceMeters: 1_850, cumulativeElapsedSeconds: 580) == true)
    }

    @Test("The final step never auto-advances and manual advance is a no-op")
    func finalStepDoesNotAdvance() {
        var state = GuidedWorkoutState(structure: tempoStructure())!  // 3 steps
        state.advance(cumulativeDistanceMeters: 500, cumulativeElapsedSeconds: 180)   // -> work
        state.advance(cumulativeDistanceMeters: 4_500, cumulativeElapsedSeconds: 1_200) // -> cool-down
        #expect(state.isOnFinalStep)
        #expect(state.nextStep == nil)
        #expect(state.shouldAutoAdvance(cumulativeDistanceMeters: 9_999, cumulativeElapsedSeconds: 9_999) == false)
        state.advance(cumulativeDistanceMeters: 9_999, cumulativeElapsedSeconds: 9_999)
        #expect(state.stepNumber == 3)   // unchanged
    }

    @Test("Manual advance early re-anchors the next step's progress to the tap point")
    func manualAdvanceReanchors() {
        var state = GuidedWorkoutState(structure: intervalStructure(reps: 1))!
        // Skip out of the warm-up early at 600 m / 200 s.
        state.advance(cumulativeDistanceMeters: 600, cumulativeElapsedSeconds: 200)
        #expect(state.currentStep.kind == .work)
        // Work progress is now measured from 600 m, not 1 000 m.
        let prog = state.progress(cumulativeDistanceMeters: 1_000, cumulativeElapsedSeconds: 320)
        #expect(prog.remainingDistanceMeters == 400)  // 800 - (1000 - 600)
    }
}

// MARK: - WorkoutKit pace-alert conversion tests (A4 / WorkoutKit)

struct WorkoutPaceAlertTests {

    @Test("A target pace maps to an inverse speed range in m/s")
    func paceToSpeedRange() {
        // 5:00/km = 300 s/km, ±8 s/km -> [292, 308] s/km -> speeds [1000/308, 1000/292].
        let range = WorkoutPaceAlert.speedRangeMetersPerSecond(forPaceSecondsPerKm: 300, toleranceSecondsPerKm: 8)
        #expect(range != nil)
        #expect(abs(range!.lowerBound - (1_000.0 / 308.0)) < 1e-6)
        #expect(abs(range!.upperBound - (1_000.0 / 292.0)) < 1e-6)
        #expect(range!.lowerBound < range!.upperBound)
    }

    @Test("A faster pace yields a higher speed band")
    func fasterPaceHigherSpeed() {
        let fast = WorkoutPaceAlert.speedRangeMetersPerSecond(forPaceSecondsPerKm: 240)!
        let slow = WorkoutPaceAlert.speedRangeMetersPerSecond(forPaceSecondsPerKm: 360)!
        #expect(fast.lowerBound > slow.upperBound)
    }

    @Test("Zero tolerance collapses the band to a single speed")
    func zeroTolerance() {
        let range = WorkoutPaceAlert.speedRangeMetersPerSecond(forPaceSecondsPerKm: 300, toleranceSecondsPerKm: 0)!
        #expect(abs(range.lowerBound - range.upperBound) < 1e-9)
        #expect(abs(range.lowerBound - (1_000.0 / 300.0)) < 1e-9)
    }

    @Test("Non-positive pace produces no alert")
    func nonPositivePace() {
        #expect(WorkoutPaceAlert.speedRangeMetersPerSecond(forPaceSecondsPerKm: 0) == nil)
        #expect(WorkoutPaceAlert.speedRangeMetersPerSecond(forPaceSecondsPerKm: -120) == nil)
    }

    @Test("Bounds stay ordered even when tolerance exceeds the pace")
    func largeToleranceStaysOrdered() {
        let range = WorkoutPaceAlert.speedRangeMetersPerSecond(forPaceSecondsPerKm: 5, toleranceSecondsPerKm: 100)!
        #expect(range.lowerBound <= range.upperBound)
    }
}
