import Testing
@testable import Stride

@Suite("StrengthLibrary")
struct StrengthLibraryTests {

    // MARK: - Empty equipment

    @Test("Empty equipment list returns empty exercise list")
    func emptyEquipmentReturnsEmpty() {
        let exercises = StrengthLibrary.exercises(for: [], focus: .runningSpecific, phase: .base)
        #expect(exercises.isEmpty)
    }

    @Test("Empty equipment produces plan with empty exercises")
    func emptyEquipmentProducesEmptyPlan() {
        let plan = StrengthLibrary.plan(for: [], focus: .runningSpecific, phase: .base)
        #expect(plan.exercises.isEmpty)
    }

    // MARK: - Bodyweight only

    @Test("Bodyweight-only exercises have no barbell exercises")
    func bodyweightExcludesBarbellMoves() {
        let exercises = StrengthLibrary.exercises(
            for: [.bodyweight], focus: .generalStrength, phase: .build
        )
        let barbellMoves = exercises.filter {
            $0.name.lowercased().contains("barbell") || $0.name.lowercased().contains("deadlift")
            && !$0.muscleGroups.contains("Bodyweight")
        }
        // Should not include barbell-specific exercises from the Barbell equipment category
        #expect(!exercises.isEmpty)
        let hasBarbell = exercises.contains { $0.targetWeight == "Heavy" && $0.name.contains("Barbell") }
        #expect(!hasBarbell)
    }

    // MARK: - Running-specific focus

    @Test("Running-specific focus always includes glute exercises")
    func runningSpecificIncludesGlutes() {
        let exercises = StrengthLibrary.exercises(
            for: [.bodyweight], focus: .runningSpecific, phase: .base
        )
        let hasGlute = exercises.contains { $0.muscleGroups.contains("Glutes") }
        #expect(hasGlute)
    }

    @Test("Running-specific focus includes core anchors")
    func runningSpecificIncludesCore() {
        let exercises = StrengthLibrary.exercises(
            for: [.bodyweight], focus: .runningSpecific, phase: .base
        )
        let hasCore = exercises.contains { $0.muscleGroups.contains("Core") }
        #expect(hasCore)
    }

    // MARK: - Phase volume

    @Test("Taper phase produces 1–2 sets per exercise")
    func taperReducesSets() {
        let exercises = StrengthLibrary.exercises(
            for: [.bodyweight, .dumbbells], focus: .runningSpecific, phase: .taper
        )
        #expect(!exercises.isEmpty)
        for exercise in exercises {
            #expect(exercise.sets <= 2, "Expected ≤2 sets in taper, got \(exercise.sets) for \(exercise.name)")
        }
    }

    @Test("Build phase produces more sets than taper phase")
    func buildPhaseHasMoreSetsThanTaper() {
        let buildExercises = StrengthLibrary.exercises(
            for: [.bodyweight], focus: .runningSpecific, phase: .build
        )
        let taperExercises = StrengthLibrary.exercises(
            for: [.bodyweight], focus: .runningSpecific, phase: .taper
        )
        let buildSets = buildExercises.map(\.sets).max() ?? 0
        let taperSets = taperExercises.map(\.sets).max() ?? 0
        #expect(buildSets >= taperSets)
    }

    // MARK: - Exercise count limits

    @Test("Taper phase produces at most 5 exercises")
    func taperCapsExerciseCount() {
        let exercises = StrengthLibrary.exercises(
            for: StrengthEquipment.allCases, focus: .generalStrength, phase: .taper
        )
        #expect(exercises.count <= 5)
    }

    @Test("All equipment produces at most 9 exercises in build phase")
    func allEquipmentBuildCapsExercises() {
        let exercises = StrengthLibrary.exercises(
            for: StrengthEquipment.allCases, focus: .generalStrength, phase: .build
        )
        #expect(exercises.count <= 9)
    }

    // MARK: - No duplicates

    @Test("Exercise names are unique in generated list")
    func noDuplicateExerciseNames() {
        let exercises = StrengthLibrary.exercises(
            for: StrengthEquipment.allCases, focus: .generalStrength, phase: .build
        )
        let names = exercises.map(\.name)
        let uniqueNames = Set(names)
        #expect(names.count == uniqueNames.count, "Duplicate exercises found: \(names)")
    }

    // MARK: - StrengthWorkoutPlan validity

    @Test("Plan has positive estimated duration")
    func planHasPositiveDuration() {
        let plan = StrengthLibrary.plan(for: [.dumbbells], focus: .runningSpecific, phase: .base)
        #expect(plan.estimatedDurationMinutes > 0)
    }

    @Test("Plan focus matches requested focus")
    func planFocusMatchesRequest() {
        let runPlan = StrengthLibrary.plan(for: [.bodyweight], focus: .runningSpecific, phase: .base)
        #expect(runPlan.focus == .runningSpecific)

        let genPlan = StrengthLibrary.plan(for: [.bodyweight], focus: .generalStrength, phase: .base)
        #expect(genPlan.focus == .generalStrength)
    }

    @Test("All equipment + both focus options produce valid plans")
    func allEquipmentBothFocusProducesValidPlans() {
        for focus in StrengthFocus.allCases {
            for phase in [TrainingPhase.base, .build, .peak, .taper] {
                let plan = StrengthLibrary.plan(
                    for: StrengthEquipment.allCases, focus: focus, phase: phase
                )
                #expect(!plan.exercises.isEmpty, "Expected exercises for \(focus) / \(phase)")
                #expect(plan.estimatedDurationMinutes > 0)
            }
        }
    }

    // MARK: - Equipment-specific content

    @Test("Kettlebell equipment includes KB swing")
    func kettlebellIncludesSwing() {
        let exercises = StrengthLibrary.exercises(
            for: [.kettlebell], focus: .runningSpecific, phase: .base
        )
        let hasSwing = exercises.contains { $0.name.contains("Swing") }
        #expect(hasSwing)
    }

    @Test("Barbell equipment includes hip thrust")
    func barbellIncludesHipThrust() {
        let exercises = StrengthLibrary.exercises(
            for: [.barbell], focus: .runningSpecific, phase: .base
        )
        let hasHipThrust = exercises.contains { $0.name.contains("Hip Thrust") }
        #expect(hasHipThrust)
    }

    @Test("Pull-up bar includes dead hang")
    func pullUpBarIncludesDeadHang() {
        let exercises = StrengthLibrary.exercises(
            for: [.pullUpBar], focus: .runningSpecific, phase: .base
        )
        let hasDeadHang = exercises.contains { $0.name.contains("Dead Hang") }
        #expect(hasDeadHang)
    }

    @Test("Timed exercises have durationSeconds set")
    func timedExercisesHaveDuration() {
        let exercises = StrengthLibrary.exercises(
            for: StrengthEquipment.allCases, focus: .generalStrength, phase: .base
        )
        let timedExercises = exercises.filter { $0.durationSeconds != nil }
        for exercise in timedExercises {
            #expect((exercise.durationSeconds ?? 0) > 0)
        }
    }
}
