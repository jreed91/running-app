import Foundation

// MARK: - CustomWorkoutRules

/// What a runner-built workout must be before it is saved, and the totals it is shown and
/// stored with (Custom workouts, PR 1).
///
/// Pure and `Sendable`, so the builder screen, the tests and anything that saves a
/// ``SavedWorkout`` agree on one set of rules. The limits are generous on purpose: they
/// are there to keep a typo (a 500-rep set, a 0:30/km pace) from reaching the guided
/// stepper and the Workout app, not to second-guess a hard session.
enum CustomWorkoutRules {

    // MARK: Limits

    static let maxNameLength = 60
    static let maxSets = 20
    static let repetitionRange = 1...50
    /// Any one segment: a marathon and change.
    static let maxSegmentMeters: Double = 50_000
    /// Any one segment: four hours.
    static let maxSegmentSeconds: Double = 4 * 3_600
    /// 2:30/km to 20:00/km. Faster is a typo; slower is a walk with no pace to hold.
    static let paceRange: ClosedRange<Double> = 150...1_200
    /// Steps once the sets are unrolled, as ``GuidedWorkoutState/flatten(_:)`` does.
    static let maxSteps = 100

    // MARK: Problems

    /// One reason a workout cannot be saved yet. `setIndex` is 0-based.
    enum Problem: Equatable, Sendable {
        case missingName
        case nameTooLong
        case noSets
        case tooManySets
        case repetitionsOutOfRange(setIndex: Int)
        case repHasNoLength(setIndex: Int)
        case segmentTooLong
        case paceOutOfRange
        case tooManySteps

        /// The line the builder shows under the field.
        var message: String {
            switch self {
            case .missingName:
                String(
                    localized: "Give the workout a name.",
                    comment: "Custom workout validation"
                )
            case .nameTooLong:
                String(
                    localized: "Keep the name to \(CustomWorkoutRules.maxNameLength) characters or fewer.",
                    comment: "Custom workout validation"
                )
            case .noSets:
                String(
                    localized: "Add at least one set of reps.",
                    comment: "Custom workout validation"
                )
            case .tooManySets:
                String(
                    localized: "A workout can have up to \(CustomWorkoutRules.maxSets) sets.",
                    comment: "Custom workout validation"
                )
            case .repetitionsOutOfRange(let index):
                String(
                    localized: "Set \(index + 1) needs 1 to \(CustomWorkoutRules.repetitionRange.upperBound) reps.",
                    comment: "Custom workout validation"
                )
            case .repHasNoLength(let index):
                String(
                    localized: "Give the reps in set \(index + 1) a distance or a time.",
                    comment: "Custom workout validation"
                )
            case .segmentTooLong:
                String(
                    localized: "A single step can be up to 50 km or 4 hours.",
                    comment: "Custom workout validation"
                )
            case .paceOutOfRange:
                String(
                    localized: "Pick a pace between 2:30 and 20:00 per kilometre.",
                    comment: "Custom workout validation"
                )
            case .tooManySteps:
                String(
                    localized: "That's more than \(CustomWorkoutRules.maxSteps) steps. Try fewer reps or sets.",
                    comment: "Custom workout validation"
                )
            }
        }
    }

    /// Everything wrong with `structure` named `name`, in the order the builder lays the
    /// fields out. Empty means it can be saved.
    static func problems(name: String, structure: WorkoutStructure) -> [Problem] {
        var out: [Problem] = []

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            out.append(.missingName)
        } else if trimmed.count > maxNameLength {
            out.append(.nameTooLong)
        }

        if structure.mainSets.isEmpty {
            out.append(.noSets)
        } else if structure.mainSets.count > maxSets {
            out.append(.tooManySets)
        }

        var repetitionsInRange = true
        for (index, set) in structure.mainSets.enumerated() {
            if !repetitionRange.contains(set.repetitions) {
                out.append(.repetitionsOutOfRange(setIndex: index))
                repetitionsInRange = false
            }
            if !hasLength(set.workSegment) {
                out.append(.repHasNoLength(setIndex: index))
            }
        }

        let segments = [structure.warmup, structure.cooldown]
            + structure.mainSets.flatMap { [$0.workSegment, $0.recoverySegment] }
        if segments.contains(where: isTooLong) {
            out.append(.segmentTooLong)
        }
        if segments.contains(where: { $0.targetPaceSecondsPerKm.map { !paceRange.contains($0) } ?? false }) {
            out.append(.paceOutOfRange)
        }

        // Only worth unrolling once reps and sets are in range, which bounds the work.
        if repetitionsInRange, structure.mainSets.count <= maxSets,
           GuidedWorkoutState.flatten(structure).count > maxSteps {
            out.append(.tooManySteps)
        }
        return out
    }

    private static func hasLength(_ segment: WorkoutSegment) -> Bool {
        (segment.distanceMeters ?? 0) > 0 || (segment.durationSeconds ?? 0) > 0
    }

    private static func isTooLong(_ segment: WorkoutSegment) -> Bool {
        (segment.distanceMeters ?? 0) > maxSegmentMeters || (segment.durationSeconds ?? 0) > maxSegmentSeconds
    }

    // MARK: Totals

    /// The paces a step with no pace of its own is costed at, in seconds per kilometre.
    struct FallbackPaces: Equatable, Sendable {
        /// Warm-up, cool-down and recovery.
        var easy: Double
        /// A rep with no target pace.
        var work: Double

        /// 6:30/km and 5:00/km, for a runner whose training paces are not known yet.
        static let standard = FallbackPaces(easy: 390, work: 300)

        init(easy: Double, work: Double) {
            self.easy = easy
            self.work = work
        }

        /// The easy end of the runner's easy band, and their threshold pace for reps.
        init(paces: TrainingPaces) {
            self.init(easy: paces.easyRange.upperBound, work: paces.threshold)
        }
    }

    /// Estimated distance and time for the session as it will actually run: the steps
    /// ``GuidedWorkoutState/flatten(_:)`` produces, so the recovery after the last rep (which
    /// is not run) is not counted, and a left-out warm-up costs nothing.
    ///
    /// A distance step is timed at its pace, a time step is measured at its pace, and a step
    /// with no pace uses `fallback`. An open step adds nothing: there is no knowing how long
    /// the runner will take before tapping Next.
    static func estimate(
        _ structure: WorkoutStructure,
        fallback: FallbackPaces = .standard
    ) -> (distanceMeters: Double, durationSeconds: Double) {
        var meters = 0.0
        var seconds = 0.0
        for step in GuidedWorkoutState.flatten(structure) {
            let pace = step.targetPaceSecondsPerKm.flatMap { $0 > 0 ? $0 : nil }
                ?? (step.kind == .work ? fallback.work : fallback.easy)
            switch step.target {
            case .distance(let stepMeters):
                meters += stepMeters
                seconds += stepMeters / 1_000 * pace
            case .time(let stepSeconds):
                seconds += stepSeconds
                meters += stepSeconds / pace * 1_000
            case .open:
                break
            }
        }
        return (meters, seconds)
    }

    /// `structure` with its stored totals set from ``estimate(_:fallback:)``, the form a
    /// ``SavedWorkout`` keeps. The totals are what lists, the plan and the Watch show
    /// before the session is run, so they are written once at save rather than worked out
    /// by every reader.
    static func finalized(
        _ structure: WorkoutStructure,
        fallback: FallbackPaces = .standard
    ) -> WorkoutStructure {
        var out = structure
        let totals = estimate(structure, fallback: fallback)
        out.totalEstimatedDistanceMeters = totals.distanceMeters.rounded()
        out.totalEstimatedDurationSeconds = totals.durationSeconds.rounded()
        return out
    }
}
