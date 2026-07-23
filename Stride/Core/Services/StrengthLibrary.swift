import Foundation

// MARK: - StrengthLibrary

/// Pure-value exercise catalog and plan generator for strength workouts.
/// No UI dependencies — fully unit-testable.
struct StrengthLibrary: Sendable {

    // MARK: - Public API

    static func plan(
        for equipment: [StrengthEquipment],
        focus: StrengthFocus,
        phase: TrainingPhase
    ) -> StrengthWorkoutPlan {
        let exercises = self.exercises(for: equipment, focus: focus, phase: phase)
        let duration = estimatedDuration(exercises: exercises, phase: phase)
        let focusNote = focus == .runningSpecific
            ? "Focus on controlled movement and single-leg stability."
            : "Full range of motion. Rest 60–90 s between sets."
        return StrengthWorkoutPlan(
            focus: focus,
            exercises: exercises,
            estimatedDurationMinutes: duration,
            notes: focusNote
        )
    }

    static func exercises(
        for equipment: [StrengthEquipment],
        focus: StrengthFocus,
        phase: TrainingPhase
    ) -> [StrengthExercise] {
        guard !equipment.isEmpty else { return [] }
        let (sets, reps) = volumeForPhase(phase)
        var result: [StrengthExercise] = []

        // Always add bodyweight core/glute anchors for running-specific focus
        if focus == .runningSpecific {
            result += runningSpecificAnchors(sets: sets, reps: reps)
        }

        // Equipment-specific exercises, added in focus-relevance order so that when the
        // list is capped below, the most relevant equipment survives instead of whichever
        // equipment happened to sort first alphabetically.
        for item in prioritizedEquipment(equipment, focus: focus) {
            result += exercisesFor(item, focus: focus, sets: sets, reps: reps)
        }

        // Deduplicate by name (equipment may overlap) and cap total
        var seen = Set<String>()
        result = result.filter { seen.insert($0.name).inserted }

        let maxExercises = maxExerciseCount(phase: phase, focus: focus)
        return Array(result.prefix(maxExercises))
    }

    // MARK: - Equipment Prioritization

    /// Orders the selected equipment by relevance to the training focus. The exercise
    /// list is capped in `exercises(for:)`, so this decides which equipment's moves
    /// survive the cap. Running-specific focus prioritizes glute/posterior-chain and
    /// single-leg tools; general-strength focus prioritizes heavy compound loading.
    /// Ties are impossible (each equipment has a distinct rank), so the result is stable.
    static func prioritizedEquipment(
        _ equipment: [StrengthEquipment],
        focus: StrengthFocus
    ) -> [StrengthEquipment] {
        equipment.sorted { relevanceRank(of: $0, focus: focus) < relevanceRank(of: $1, focus: focus) }
    }

    private static func relevanceRank(of equipment: StrengthEquipment, focus: StrengthFocus) -> Int {
        let order: [StrengthEquipment]
        switch focus {
        case .runningSpecific:
            // Activation/single-leg tools first; heavy general lifting last.
            order = [.resistanceBands, .bodyweight, .kettlebell, .dumbbells, .pullUpBar, .barbell]
        case .generalStrength:
            // Compound loading tools first; activation bands last.
            order = [.barbell, .dumbbells, .kettlebell, .pullUpBar, .bodyweight, .resistanceBands]
        }
        return order.firstIndex(of: equipment) ?? order.count
    }

    // MARK: - Phase Volume

    private static func volumeForPhase(_ phase: TrainingPhase) -> (sets: Int, reps: Int) {
        switch phase {
        case .base:  return (3, 12)
        case .build: return (4, 10)
        case .peak:  return (3, 8)
        case .taper: return (2, 10)
        }
    }

    private static func maxExerciseCount(phase: TrainingPhase, focus: StrengthFocus) -> Int {
        switch phase {
        case .base:  return focus == .runningSpecific ? 7 : 8
        case .build: return focus == .runningSpecific ? 8 : 9
        case .peak:  return focus == .runningSpecific ? 6 : 7
        case .taper: return 5
        }
    }

    private static func estimatedDuration(exercises: [StrengthExercise], phase: TrainingPhase) -> Int {
        let restBetweenSets = 60
        let secsPerRep = 4
        let secsPerSet = exercises.reduce(0) { total, ex in
            let workTime = ex.durationSeconds ?? (ex.reps * secsPerRep)
            return total + (ex.sets * (workTime + restBetweenSets))
        }
        return max(20, (secsPerSet + 300) / 60) // 300 s warm-up/cool-down buffer
    }

    // MARK: - Running-Specific Anchors (bodyweight glute/core)

    private static func runningSpecificAnchors(sets: Int, reps: Int) -> [StrengthExercise] {
        [
            StrengthExercise(
                name: "Glute Bridge",
                sets: sets, reps: reps,
                targetWeight: "Bodyweight",
                muscleGroups: ["Glutes", "Hamstrings"]
            ),
            StrengthExercise(
                name: "Dead Bug",
                sets: sets, reps: reps,
                targetWeight: "Bodyweight",
                notes: "Extend opposite arm and leg. Keep lower back flat.",
                muscleGroups: ["Core"]
            ),
            StrengthExercise(
                name: "Calf Raise",
                sets: sets, reps: max(reps, 15),
                targetWeight: "Bodyweight",
                muscleGroups: ["Calves"]
            ),
        ]
    }

    // MARK: - Per-Equipment Exercises

    private static func exercisesFor(
        _ equipment: StrengthEquipment,
        focus: StrengthFocus,
        sets: Int,
        reps: Int
    ) -> [StrengthExercise] {
        switch equipment {
        case .bodyweight:
            return bodyweightExercises(focus: focus, sets: sets, reps: reps)
        case .dumbbells:
            return dumbbellExercises(focus: focus, sets: sets, reps: reps)
        case .resistanceBands:
            return bandExercises(focus: focus, sets: sets, reps: reps)
        case .pullUpBar:
            return pullUpBarExercises(focus: focus, sets: sets, reps: reps)
        case .kettlebell:
            return kettlebellExercises(focus: focus, sets: sets, reps: reps)
        case .barbell:
            return barbellExercises(focus: focus, sets: sets, reps: reps)
        }
    }

    // MARK: Bodyweight

    private static func bodyweightExercises(
        focus: StrengthFocus, sets: Int, reps: Int
    ) -> [StrengthExercise] {
        var exercises = [
            StrengthExercise(
                name: "Single-Leg Deadlift",
                sets: sets, reps: reps,
                targetWeight: "Bodyweight",
                notes: "Hinge at the hip. Keep the back leg straight and spine neutral.",
                muscleGroups: ["Hamstrings", "Glutes", "Balance"]
            ),
            StrengthExercise(
                name: "Walking Lunge",
                sets: sets, reps: reps,
                targetWeight: "Bodyweight",
                muscleGroups: ["Quads", "Glutes", "Hip Flexors"]
            ),
            StrengthExercise(
                name: "Step-Up",
                sets: sets, reps: reps,
                targetWeight: "Bodyweight",
                notes: "Drive through the heel of the raised leg.",
                muscleGroups: ["Glutes", "Quads"]
            ),
            StrengthExercise(
                name: "Copenhagen Plank",
                sets: sets, reps: nil, durationSeconds: 20,
                targetWeight: "Bodyweight",
                notes: "Side plank with top leg on a bench or step.",
                muscleGroups: ["Adductors", "Core"]
            ),
        ]
        if focus == .generalStrength {
            exercises += [
                StrengthExercise(
                    name: "Push-Up",
                    sets: sets, reps: reps,
                    targetWeight: "Bodyweight",
                    muscleGroups: ["Chest", "Triceps", "Shoulders"]
                ),
                StrengthExercise(
                    name: "Plank",
                    sets: sets, reps: nil, durationSeconds: 30,
                    targetWeight: "Bodyweight",
                    muscleGroups: ["Core"]
                ),
            ]
        }
        return exercises
    }

    // MARK: Dumbbells

    private static func dumbbellExercises(
        focus: StrengthFocus, sets: Int, reps: Int
    ) -> [StrengthExercise] {
        var exercises = [
            StrengthExercise(
                name: "DB Romanian Deadlift",
                sets: sets, reps: reps,
                targetWeight: "Moderate",
                notes: "Hinge at the hips, slight knee bend, bar path close to legs.",
                muscleGroups: ["Hamstrings", "Glutes", "Lower Back"]
            ),
            StrengthExercise(
                name: "DB Goblet Squat",
                sets: sets, reps: reps,
                targetWeight: "Moderate",
                muscleGroups: ["Quads", "Glutes", "Core"]
            ),
            StrengthExercise(
                name: "DB Lateral Lunge",
                sets: sets, reps: reps,
                targetWeight: "Light",
                muscleGroups: ["Glutes", "Adductors", "Quads"]
            ),
            StrengthExercise(
                name: "DB Step-Up with Knee Drive",
                sets: sets, reps: reps,
                targetWeight: "Light",
                notes: "Drive the knee up at the top for hip flexor activation.",
                muscleGroups: ["Glutes", "Quads", "Hip Flexors"]
            ),
        ]
        if focus == .generalStrength {
            exercises += [
                StrengthExercise(
                    name: "DB Overhead Press",
                    sets: sets, reps: reps,
                    targetWeight: "Moderate",
                    muscleGroups: ["Shoulders", "Triceps"]
                ),
                StrengthExercise(
                    name: "DB Bent-Over Row",
                    sets: sets, reps: reps,
                    targetWeight: "Moderate",
                    muscleGroups: ["Back", "Biceps"]
                ),
                StrengthExercise(
                    name: "DB Bench Press",
                    sets: sets, reps: reps,
                    targetWeight: "Moderate",
                    muscleGroups: ["Chest", "Triceps"]
                ),
            ]
        }
        return exercises
    }

    // MARK: Resistance Bands

    private static func bandExercises(
        focus: StrengthFocus, sets: Int, reps: Int
    ) -> [StrengthExercise] {
        var exercises = [
            StrengthExercise(
                name: "Monster Walk",
                sets: sets, reps: reps,
                targetWeight: "Band",
                notes: "Band around ankles. Stay low, take lateral steps.",
                muscleGroups: ["Glutes", "Hip Abductors"]
            ),
            StrengthExercise(
                name: "Banded Glute Bridge",
                sets: sets, reps: reps,
                targetWeight: "Band",
                notes: "Band just above knees. Press knees out at the top.",
                muscleGroups: ["Glutes", "Hamstrings"]
            ),
            StrengthExercise(
                name: "Fire Hydrant",
                sets: sets, reps: reps,
                targetWeight: "Band",
                notes: "On all fours. Lift knee out to 45° keeping hip stable.",
                muscleGroups: ["Glutes", "Hip Abductors"]
            ),
        ]
        if focus == .generalStrength {
            exercises += [
                StrengthExercise(
                    name: "Banded Pull-Apart",
                    sets: sets, reps: reps,
                    targetWeight: "Band",
                    notes: "Hold band at chest height, pull apart to 'T' position.",
                    muscleGroups: ["Rear Delts", "Upper Back"]
                ),
                StrengthExercise(
                    name: "Pallof Press",
                    sets: sets, reps: reps,
                    targetWeight: "Band",
                    notes: "Anchor band at chest height. Press straight out and return.",
                    muscleGroups: ["Core", "Obliques"]
                ),
            ]
        }
        return exercises
    }

    // MARK: Pull-Up Bar

    private static func pullUpBarExercises(
        focus: StrengthFocus, sets: Int, reps: Int
    ) -> [StrengthExercise] {
        var exercises = [
            StrengthExercise(
                name: "Hanging Knee Raise",
                sets: sets, reps: reps,
                targetWeight: "Bodyweight",
                muscleGroups: ["Core", "Hip Flexors"]
            ),
            StrengthExercise(
                name: "Dead Hang",
                sets: sets, reps: nil, durationSeconds: 30,
                targetWeight: "Bodyweight",
                notes: "Builds grip strength and decompresses the spine.",
                muscleGroups: ["Grip", "Lats", "Shoulders"]
            ),
            StrengthExercise(
                name: "Scapular Pull-Up",
                sets: sets, reps: reps,
                targetWeight: "Bodyweight",
                notes: "From a dead hang, depress the shoulder blades without bending elbows.",
                muscleGroups: ["Lats", "Rhomboids"]
            ),
        ]
        if focus == .generalStrength {
            exercises += [
                StrengthExercise(
                    name: "Pull-Up",
                    sets: sets, reps: max(reps / 2, 3),
                    targetWeight: "Bodyweight",
                    muscleGroups: ["Lats", "Biceps", "Back"]
                ),
            ]
        }
        return exercises
    }

    // MARK: Kettlebell

    private static func kettlebellExercises(
        focus: StrengthFocus, sets: Int, reps: Int
    ) -> [StrengthExercise] {
        var exercises = [
            StrengthExercise(
                name: "Kettlebell Swing",
                sets: sets, reps: max(reps, 15),
                targetWeight: "Moderate",
                notes: "Drive with the hips. Keep the bell at hip height at the top.",
                muscleGroups: ["Glutes", "Hamstrings", "Core"]
            ),
            StrengthExercise(
                name: "Single-Leg KB Deadlift",
                sets: sets, reps: reps,
                targetWeight: "Light",
                muscleGroups: ["Hamstrings", "Glutes", "Balance"]
            ),
            StrengthExercise(
                name: "KB Goblet Squat",
                sets: sets, reps: reps,
                targetWeight: "Moderate",
                muscleGroups: ["Quads", "Glutes", "Core"]
            ),
        ]
        if focus == .generalStrength {
            exercises += [
                StrengthExercise(
                    name: "KB Turkish Get-Up",
                    sets: max(sets - 1, 2), reps: max(reps / 5, 3),
                    targetWeight: "Light",
                    notes: "Slow and controlled. 3 reps per side.",
                    muscleGroups: ["Full Body", "Core", "Shoulders"]
                ),
                StrengthExercise(
                    name: "KB Press",
                    sets: sets, reps: reps,
                    targetWeight: "Moderate",
                    muscleGroups: ["Shoulders", "Triceps"]
                ),
            ]
        }
        return exercises
    }

    // MARK: Barbell

    private static func barbellExercises(
        focus: StrengthFocus, sets: Int, reps: Int
    ) -> [StrengthExercise] {
        var exercises = [
            StrengthExercise(
                name: "Barbell Hip Thrust",
                sets: sets, reps: reps,
                targetWeight: "Heavy",
                notes: "Upper back on a bench. Drive hips to full extension.",
                muscleGroups: ["Glutes", "Hamstrings"]
            ),
            StrengthExercise(
                name: "Romanian Deadlift",
                sets: sets, reps: reps,
                targetWeight: "Moderate",
                muscleGroups: ["Hamstrings", "Glutes", "Lower Back"]
            ),
            StrengthExercise(
                name: "Good Morning",
                sets: sets, reps: reps,
                targetWeight: "Light",
                notes: "Bar on upper back. Hinge forward keeping spine neutral.",
                muscleGroups: ["Hamstrings", "Glutes", "Lower Back"]
            ),
        ]
        if focus == .generalStrength {
            exercises += [
                StrengthExercise(
                    name: "Back Squat",
                    sets: sets, reps: reps,
                    targetWeight: "Heavy",
                    muscleGroups: ["Quads", "Glutes", "Core"]
                ),
                StrengthExercise(
                    name: "Deadlift",
                    sets: max(sets - 1, 2), reps: max(reps / 2, 3),
                    targetWeight: "Heavy",
                    notes: "Keep the bar close to the legs throughout the lift.",
                    muscleGroups: ["Full Body", "Hamstrings", "Back"]
                ),
                StrengthExercise(
                    name: "Barbell Row",
                    sets: sets, reps: reps,
                    targetWeight: "Moderate",
                    muscleGroups: ["Back", "Biceps"]
                ),
                StrengthExercise(
                    name: "Bench Press",
                    sets: sets, reps: reps,
                    targetWeight: "Moderate",
                    muscleGroups: ["Chest", "Triceps", "Shoulders"]
                ),
            ]
        }
        return exercises
    }
}

// MARK: - StrengthExercise convenience init

private extension StrengthExercise {
    init(
        name: String,
        sets: Int,
        reps: Int?,
        durationSeconds: Int? = nil,
        targetWeight: String? = nil,
        notes: String? = nil,
        muscleGroups: [String]
    ) {
        self.name = name
        self.sets = sets
        self.reps = reps ?? 0
        self.durationSeconds = durationSeconds
        self.targetWeight = targetWeight
        self.notes = notes
        self.muscleGroups = muscleGroups
    }
}
