import Foundation

// MARK: - How to do each exercise

extension StrengthLibrary {

    /// Three short cues for an exercise: the set-up, the movement, and the thing most
    /// people get wrong. Nil for a name the library doesn't have.
    ///
    /// Written for a runner with no coach in the room, so each cue is something to do,
    /// not anatomy. Keyed by the library's own names; a test checks every exercise the
    /// library can produce has cues, so a new exercise can't ship without them.
    public static func cues(forExerciseNamed name: String) -> [String]? {
        guidance[name]
    }

    private static let guidance: [String: [String]] = [
        // Running-specific anchors
        "Glute Bridge": [
            "Lie on your back, knees bent, feet flat and hip-width apart.",
            "Push through your heels and lift your hips until knees, hips and shoulders line up.",
            "Squeeze your glutes at the top. Don't arch your lower back to get higher.",
        ],
        "Dead Bug": [
            "Lie on your back with arms up and knees bent over your hips.",
            "Lower the opposite arm and leg towards the floor, then swap sides.",
            "Keep your lower back pressed into the floor the whole time. Go slower if it lifts.",
        ],
        "Calf Raise": [
            "Stand on the edge of a step with your heels hanging off, holding something for balance.",
            "Rise up onto your toes as high as you can, then lower your heels below the step.",
            "Take two seconds down. Do it on one leg when two gets easy.",
        ],

        // Bodyweight
        "Single-Leg Deadlift": [
            "Stand on one leg with a soft knee.",
            "Hinge at the hips, reaching your hands down as the free leg goes back.",
            "Keep your hips square to the floor. Stop when your back starts to round.",
        ],
        "Walking Lunge": [
            "Step forward into a long stride and lower until both knees are near 90°.",
            "Drive through the front heel to step straight into the next lunge.",
            "Keep your front knee over your foot, not caving inwards.",
        ],
        "Step-Up": [
            "Put one foot flat on a sturdy box or step, about knee height.",
            "Push through that heel to stand up tall on the step, then step down slowly.",
            "Let the top leg do the work. Don't push off the back foot.",
        ],
        "Copenhagen Plank": [
            "Lie on your side with your top leg resting on a bench at the knee or ankle.",
            "Lift your hips so your body makes a straight line, the bottom leg off the floor if you can.",
            "Start with the knee on the bench. Moving to the ankle makes it much harder.",
        ],
        "Push-Up": [
            "Hands a little wider than your shoulders, body in one straight line.",
            "Lower your chest to just above the floor, elbows at about 45° to your body.",
            "Don't let your hips sag. Drop to your knees to finish a set.",
        ],
        "Plank": [
            "Forearms on the floor, elbows under your shoulders, legs straight.",
            "Brace as if someone is about to poke your stomach, and squeeze your glutes.",
            "Keep a straight line from head to heels. Stop the set when your hips drop.",
        ],

        // Dumbbells
        "DB Romanian Deadlift": [
            "Stand tall holding the dumbbells in front of your thighs.",
            "Push your hips back and slide the weights down your legs with a slight knee bend.",
            "Stop when you feel your hamstrings stretch, before your back rounds, then drive your hips forward.",
        ],
        "DB Goblet Squat": [
            "Hold one dumbbell upright against your chest, feet just wider than your hips.",
            "Sit down between your heels, elbows inside your knees.",
            "Keep your chest up and your heels down the whole way.",
        ],
        "DB Lateral Lunge": [
            "Stand with feet together, a dumbbell in each hand or one at your chest.",
            "Take a wide step to the side and sit back into that hip, the other leg straight.",
            "Keep the bent knee in line with your toes and push back to the start.",
        ],
        "DB Step-Up with Knee Drive": [
            "Hold the dumbbells at your sides with one foot on a box.",
            "Stand up on the box and drive the other knee up to hip height.",
            "Lower slowly. Keep the top leg doing the work.",
        ],
        "DB Overhead Press": [
            "Hold the dumbbells at your shoulders, palms forward, ribs down.",
            "Press straight up until your arms are locked out by your ears.",
            "Don't lean back to finish the rep. Squeeze your glutes to stay upright.",
        ],
        "DB Bent-Over Row": [
            "Hinge forward with a flat back, the dumbbells hanging under your shoulders.",
            "Pull your elbows back towards your hips and squeeze your shoulder blades together.",
            "Keep your torso still. If you have to swing, the weight is too heavy.",
        ],
        "DB Bench Press": [
            "Lie on a bench with the dumbbells at your chest and your feet planted.",
            "Press up until your arms are straight over your chest, then lower under control.",
            "Keep your shoulder blades pulled back and down against the bench.",
        ],

        // Resistance bands
        "Monster Walk": [
            "Put a band around your legs just above the knees or ankles and sit into a quarter squat.",
            "Take small steps forwards and diagonally, keeping tension on the band.",
            "Don't let your knees cave in or your feet come together.",
        ],
        "Banded Glute Bridge": [
            "Loop a band above your knees and lie on your back, knees bent.",
            "Push your knees out against the band and lift your hips.",
            "Hold for a second at the top, knees still pushing out.",
        ],
        "Fire Hydrant": [
            "On hands and knees with a band above your knees.",
            "Lift one knee out to the side, keeping it bent, then lower it.",
            "Keep your hips level. Only the leg moves.",
        ],
        "Banded Pull-Apart": [
            "Hold a band in front of your chest, arms straight, hands shoulder-width apart.",
            "Pull the band apart until it touches your chest, squeezing your shoulder blades.",
            "Keep your shoulders down away from your ears.",
        ],
        "Pallof Press": [
            "Anchor a band at chest height and stand side-on to it, holding it at your chest.",
            "Press your hands straight out in front and hold, resisting the pull to turn.",
            "Your hips and shoulders stay facing forward. That's the exercise.",
        ],

        // Pull-up bar
        "Hanging Knee Raise": [
            "Hang from the bar with straight arms and your shoulders engaged.",
            "Bring your knees up towards your chest by curling your pelvis.",
            "Lower slowly and don't swing. Pause at the bottom if you start to.",
        ],
        "Dead Hang": [
            "Grip the bar a little wider than your shoulders and hang with straight arms.",
            "Let your body relax and breathe, feet off the floor.",
            "Step down before your grip gives out completely.",
        ],
        "Scapular Pull-Up": [
            "Hang from the bar with straight arms.",
            "Pull your shoulder blades down and together so your body rises an inch or two.",
            "Your elbows stay straight. It's a small movement.",
        ],
        "Pull-Up": [
            "Hang with your hands just wider than your shoulders, palms facing away.",
            "Pull your chest towards the bar until your chin clears it, then lower all the way.",
            "No kicking. Use a band or jump up and lower slowly if you can't do one yet.",
        ],

        // Kettlebell
        "Kettlebell Swing": [
            "Feet shoulder-width apart, the bell on the floor a foot in front of you.",
            "Hike it back between your legs, then snap your hips forward to float it to chest height.",
            "It's a hip hinge, not a squat or an arm raise. Your arms just hold on.",
        ],
        "Single-Leg KB Deadlift": [
            "Hold the bell in the hand opposite your standing leg.",
            "Hinge at the hip, the free leg going back, until the bell nears the floor.",
            "Keep your hips square and your back flat, then stand up through the heel.",
        ],
        "KB Goblet Squat": [
            "Hold the bell by its horns at your chest, feet just wider than your hips.",
            "Squat down between your heels, elbows inside your knees.",
            "Chest up, heels down, and stand up tall.",
        ],
        "KB Turkish Get-Up": [
            "Lie on your back holding the bell straight up over your shoulder, eyes on it.",
            "Roll to your elbow, then hand, lift your hips, sweep the leg under and stand, arm locked out.",
            "Reverse every step to lie back down. Learn it with no weight or a shoe on your fist first.",
        ],
        "KB Press": [
            "Hold the bell at your shoulder in the rack position, wrist straight.",
            "Press it straight overhead until your arm is locked by your ear.",
            "Squeeze your glutes and keep your ribs down. Don't lean away.",
        ],

        // Barbell
        "Barbell Hip Thrust": [
            "Sit with your upper back against a bench, the padded bar over your hips.",
            "Drive through your heels and lift your hips until your thighs are flat.",
            "Tuck your chin and keep your ribs down at the top. Don't arch your back.",
        ],
        "Romanian Deadlift": [
            "Stand with the bar in your hands at hip height.",
            "Push your hips back and slide the bar down your thighs with soft knees.",
            "Stop below your knees or when your back wants to round, then stand up by driving your hips forward.",
        ],
        "Good Morning": [
            "Bar on your upper back as for a squat, feet hip-width apart.",
            "Push your hips back and lean forward with a flat back until you feel your hamstrings.",
            "Start light. This one is about position, not load.",
        ],
        "Back Squat": [
            "Bar on your upper back, feet shoulder-width apart, toes slightly out.",
            "Sit down and back until your hips are at or below your knees, then stand up.",
            "Brace before each rep and keep your knees tracking over your toes.",
        ],
        "Deadlift": [
            "Bar over the middle of your feet, shins near it, hands just outside your legs.",
            "Brace, push the floor away and stand up tall, the bar close to your legs.",
            "Keep your back flat from start to finish. Lower it the same way.",
        ],
        "Barbell Row": [
            "Hinge forward with a flat back, the bar hanging at arm's length.",
            "Pull the bar to your lower ribs and squeeze your shoulder blades together.",
            "Keep your torso still. Use less weight before you start heaving.",
        ],
        "Bench Press": [
            "Lie with your eyes under the bar, feet planted, shoulder blades pulled back.",
            "Lower the bar to your lower chest, then press it back up over your shoulders.",
            "Use a spotter or safety arms when the weight is heavy.",
        ],
    ]

    // MARK: - Alternatives

    /// Exercises that could stand in for `exercise` with the equipment at hand: they
    /// share its main muscle group, or failing that any of its groups. Bodyweight is
    /// always at hand. The sets, reps and hold time stay the plan's, so a swap changes
    /// the movement and not the session's size. At most `limit`, closest first.
    public static func alternatives(
        to exercise: StrengthExercise,
        equipment: [StrengthEquipment],
        excluding excluded: Set<String> = [],
        limit: Int = 4
    ) -> [StrengthExercise] {
        let available = Set(equipment).union([.bodyweight])
        let groups = Set(exercise.muscleGroups)
        let primary = exercise.muscleGroups.first

        let candidates = catalog.filter { candidate in
            candidate.name != exercise.name
                && !excluded.contains(candidate.name)
                && candidate.equipment.map(available.contains) == true
                && !groups.isDisjoint(with: candidate.muscleGroups)
        }
        let ranked = candidates.sorted { lhs, rhs in
            let lhsPrimary = lhs.muscleGroups.first == primary
            let rhsPrimary = rhs.muscleGroups.first == primary
            if lhsPrimary != rhsPrimary { return lhsPrimary }
            let lhsShared = groups.intersection(lhs.muscleGroups).count
            let rhsShared = groups.intersection(rhs.muscleGroups).count
            if lhsShared != rhsShared { return lhsShared > rhsShared }
            return lhs.name < rhs.name
        }
        return ranked.prefix(limit).map { standIn($0, for: exercise) }
    }

    /// `candidate` doing `exercise`'s job: the plan's sets, and its reps unless one of the
    /// two is a timed hold. A swap changes the movement, not the session's size.
    public static func standIn(_ candidate: StrengthExercise, for exercise: StrengthExercise) -> StrengthExercise {
        var swapped = candidate
        swapped.sets = exercise.sets
        if candidate.durationSeconds != nil {
            // A hold keeps its own time: twelve "reps" of a plank means nothing.
            swapped.reps = 0
        } else {
            swapped.reps = exercise.durationSeconds != nil ? max(candidate.reps, 8) : exercise.reps
        }
        return swapped
    }

    // MARK: - Editing a session

    /// Library exercises that could be added to a session: done with equipment at hand
    /// (bodyweight always), not already in it, not excluded. Grouped by nothing, sorted
    /// by name, for a picker.
    public static func addable(
        to exercises: [StrengthExercise],
        equipment: [StrengthEquipment],
        excluding excluded: Set<String> = []
    ) -> [StrengthExercise] {
        let available = Set(equipment).union([.bodyweight])
        let present = Set(exercises.map(\.name))
        return catalog
            .filter { candidate in
                !present.contains(candidate.name)
                    && !excluded.contains(candidate.name)
                    && candidate.equipment.map(available.contains) == true
            }
            .sorted { $0.name < $1.name }
    }

    /// `candidate` ready to add to a session: the session's own sets and reps (from its
    /// first exercise done for reps), so an added move matches the day's volume. A timed
    /// hold keeps its time.
    public static func added(_ candidate: StrengthExercise, to exercises: [StrengthExercise]) -> StrengthExercise {
        guard let template = exercises.first(where: { $0.durationSeconds == nil }) ?? exercises.first else {
            return candidate
        }
        return standIn(candidate, for: template)
    }
}
