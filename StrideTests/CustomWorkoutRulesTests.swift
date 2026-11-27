import Foundation
import Testing
@testable import Stride

// MARK: - Custom workouts (PR 1): validation, totals and the saved model

struct CustomWorkoutRulesTests {

    // MARK: Fixtures

    /// 1 km warm-up, `reps` × 800 m at 4:00/km with 90 s jog, 1 km cool-down.
    private func eights(reps: Int = 6, warmup: Bool = true, cooldown: Bool = true) -> WorkoutStructure {
        WorkoutStructure(
            warmup: warmup ? WorkoutSegment(distanceMeters: 1_000, label: "Warm-up") : WorkoutSegment(label: ""),
            mainSets: [WorkoutSet(
                repetitions: reps,
                workSegment: WorkoutSegment(distanceMeters: 800, targetPaceSecondsPerKm: 240, label: ""),
                recoverySegment: WorkoutSegment(durationSeconds: 90, label: "Jog"),
                label: "800s"
            )],
            cooldown: cooldown ? WorkoutSegment(distanceMeters: 1_000, label: "Cool-down") : WorkoutSegment(label: ""),
            totalEstimatedDistanceMeters: 0,
            totalEstimatedDurationSeconds: 0
        )
    }

    private let paces = CustomWorkoutRules.FallbackPaces(easy: 360, work: 300)

    // MARK: Validation

    @Test("A complete workout has no problems")
    func validWorkout() {
        #expect(CustomWorkoutRules.problems(name: "6 × 800 m", structure: eights()).isEmpty)
    }

    @Test("A name is required and kept short")
    func nameRules() {
        #expect(CustomWorkoutRules.problems(name: "   ", structure: eights()) == [.missingName])
        let long = String(repeating: "a", count: CustomWorkoutRules.maxNameLength + 1)
        #expect(CustomWorkoutRules.problems(name: long, structure: eights()) == [.nameTooLong])
    }

    @Test("A workout needs a set, and each set's reps need a length and a sane count")
    func setRules() {
        var structure = eights()
        structure.mainSets = []
        #expect(CustomWorkoutRules.problems(name: "x", structure: structure) == [.noSets])

        structure = eights(reps: 0)
        #expect(CustomWorkoutRules.problems(name: "x", structure: structure) == [.repetitionsOutOfRange(setIndex: 0)])

        structure = eights()
        structure.mainSets[0].workSegment = WorkoutSegment(label: "Rep")
        #expect(CustomWorkoutRules.problems(name: "x", structure: structure) == [.repHasNoLength(setIndex: 0)])
    }

    @Test("Typos in pace or length are caught")
    func rangeRules() {
        var structure = eights()
        structure.mainSets[0].workSegment.targetPaceSecondsPerKm = 30
        #expect(CustomWorkoutRules.problems(name: "x", structure: structure) == [.paceOutOfRange])

        structure = eights()
        structure.warmup = WorkoutSegment(durationSeconds: 5 * 3_600, label: "Warm-up")
        #expect(CustomWorkoutRules.problems(name: "x", structure: structure) == [.segmentTooLong])
    }

    @Test("More than the step cap once unrolled is refused")
    func stepCap() {
        // 50 reps with a recovery between each is 99 steps, plus warm-up and cool-down.
        #expect(CustomWorkoutRules.problems(name: "x", structure: eights(reps: 50)) == [.tooManySteps])
        #expect(CustomWorkoutRules.problems(name: "x", structure: eights(reps: 50, warmup: false, cooldown: false)).isEmpty)
    }

    // MARK: Totals

    @Test("Totals count the steps that run: no recovery after the last rep")
    func estimateMatchesTheRun() {
        let totals = CustomWorkoutRules.estimate(eights(reps: 6), fallback: paces)
        // 2 km easy + 6 × 800 m + 5 × 90 s jog at the easy pace.
        let jogMeters = 5 * 90.0 / 360 * 1_000
        #expect(abs(totals.distanceMeters - (2_000 + 4_800 + jogMeters)) < 0.001)
        // 2 km at 6:00 + 4.8 km at 4:00 + 450 s.
        #expect(abs(totals.durationSeconds - (720 + 1_152 + 450)) < 0.001)
    }

    @Test("A left-out warm-up costs nothing; a rep with no pace uses the work pace")
    func estimateFallbacks() {
        var structure = eights(reps: 1, warmup: false, cooldown: false)
        structure.mainSets[0].workSegment.targetPaceSecondsPerKm = nil
        let totals = CustomWorkoutRules.estimate(structure, fallback: paces)
        #expect(totals.distanceMeters == 800)
        #expect(abs(totals.durationSeconds - 240) < 0.001)
    }

    @Test("finalized writes the rounded totals into the structure")
    func finalizedStoresTotals() {
        let structure = CustomWorkoutRules.finalized(eights(), fallback: paces)
        let totals = CustomWorkoutRules.estimate(eights(), fallback: paces)
        #expect(structure.totalEstimatedDistanceMeters == totals.distanceMeters.rounded())
        #expect(structure.totalEstimatedDurationSeconds == totals.durationSeconds.rounded())
    }

    // MARK: SavedWorkout

    @Test("A saved workout keeps its structure and marks edits and use")
    func savedWorkoutRoundTrip() throws {
        let created = Date(timeIntervalSince1970: 1_000)
        let workout = SavedWorkout(name: "6 × 800 m", structure: eights(), now: created)
        #expect(workout.structure == eights())
        #expect(workout.createdAt == created && workout.updatedAt == created)
        #expect(workout.lastUsedAt == nil)

        let edited = Date(timeIntervalSince1970: 2_000)
        workout.update(name: "8 × 800 m", structure: eights(reps: 8), notes: "Track", now: edited)
        #expect(workout.name == "8 × 800 m")
        #expect(workout.structure?.mainSets.first?.repetitions == 8)
        #expect(workout.notes == "Track")
        #expect(workout.updatedAt == edited && workout.createdAt == created)

        workout.markUsed(now: edited)
        #expect(workout.lastUsedAt == edited)
    }
}
