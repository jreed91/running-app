import Foundation

// MARK: - GuidedStep

/// One executable step of a guided workout, flattened from a ``WorkoutStructure``.
///
/// A structured plan workout stores its shape as warm-up → main sets (each a
/// number of work + recovery repetitions) → cool-down. To *guide* a runner
/// through it live we flatten that shape into an ordered list of concrete steps
/// — one per warm-up, per rep's work, per rep's recovery, and per cool-down —
/// each carrying the target the runner should hit before advancing.
struct GuidedStep: Equatable, Sendable {

    enum Kind: String, Equatable, Sendable {
        case warmup, work, recovery, cooldown
    }

    /// What finishes the step. Distance/time targets auto-advance; `.open`
    /// segments (a recovery with no prescribed distance or time) advance only
    /// when the runner taps "Next".
    enum Target: Equatable, Sendable {
        case distance(meters: Double)
        case time(seconds: Double)
        case open
    }

    let kind: Kind
    let label: String
    let target: Target
    /// Target pace in seconds/km, when the segment prescribes one.
    let targetPaceSecondsPerKm: Double?
    /// 1-based repetition index within a multi-rep set (e.g. rep 3 of 6). Nil for
    /// warm-up, cool-down, and single-rep sets.
    let repIndex: Int?
    /// Total repetitions in this step's set, paired with ``repIndex``.
    let repCount: Int?

    var isOpen: Bool { target == .open }
}

// MARK: - GuidedStepProgress

/// Live progress through the current step, derived purely from the tracker's
/// cumulative distance and elapsed time.
struct GuidedStepProgress: Equatable, Sendable {
    /// Completion fraction, 0...1. Always 0 for an `.open` target (indeterminate).
    let fraction: Double
    /// True once the step's distance/time target has been met. Always false for
    /// an `.open` target (which the runner must advance manually).
    let isTargetReached: Bool
    /// Remaining distance in metres for a distance-based step, else nil.
    let remainingDistanceMeters: Double?
    /// Remaining time in seconds for a time-based step, else nil.
    let remainingSeconds: Double?
}

// MARK: - GuidedWorkoutState

/// Pure, `Sendable` state machine that steps a runner through a structured
/// workout. It is deliberately free of SwiftUI, HealthKit, and the tracker so
/// the flattening and advancement logic is unit-testable in isolation
/// (per AGENTS.md — business logic in services, not views).
///
/// The tracker reports *cumulative* distance and elapsed time. This type records
/// the cumulative values at which the current step began, so progress and the
/// auto-advance decision are always measured *within* the active step.
struct GuidedWorkoutState: Equatable, Sendable {

    private(set) var steps: [GuidedStep]
    private(set) var currentIndex: Int
    /// Cumulative distance/time snapshot captured when the current step began.
    private var stepStartDistanceMeters: Double
    private var stepStartElapsedSeconds: Double

    // MARK: Init

    /// Builds the guided state for a structured workout, or returns `nil` when
    /// the structure has no meaningful multi-segment shape to guide (a flat run).
    init?(structure: WorkoutStructure) {
        let flattened = GuidedWorkoutState.flatten(structure)
        // Guided mode only earns its screen space when there is real work to
        // step through — a warm-up/cool-down-only shell is just a free run.
        guard flattened.contains(where: { $0.kind == .work }) else { return nil }
        self.steps = flattened
        self.currentIndex = 0
        self.stepStartDistanceMeters = 0
        self.stepStartElapsedSeconds = 0
    }

    // MARK: Derived

    var currentStep: GuidedStep { steps[currentIndex] }
    var stepNumber: Int { currentIndex + 1 }
    var stepCount: Int { steps.count }
    var isOnFinalStep: Bool { currentIndex >= steps.count - 1 }
    var nextStep: GuidedStep? { isOnFinalStep ? nil : steps[currentIndex + 1] }

    // MARK: Progress

    func progress(
        cumulativeDistanceMeters distance: Double,
        cumulativeElapsedSeconds elapsed: Double
    ) -> GuidedStepProgress {
        let inStepDistance = max(0, distance - stepStartDistanceMeters)
        let inStepTime = max(0, elapsed - stepStartElapsedSeconds)

        switch currentStep.target {
        case .distance(let meters):
            let fraction = meters > 0 ? min(1, inStepDistance / meters) : 1
            return GuidedStepProgress(
                fraction: fraction,
                isTargetReached: inStepDistance >= meters,
                remainingDistanceMeters: max(0, meters - inStepDistance),
                remainingSeconds: nil
            )
        case .time(let seconds):
            let fraction = seconds > 0 ? min(1, inStepTime / seconds) : 1
            return GuidedStepProgress(
                fraction: fraction,
                isTargetReached: inStepTime >= seconds,
                remainingDistanceMeters: nil,
                remainingSeconds: max(0, seconds - inStepTime)
            )
        case .open:
            return GuidedStepProgress(
                fraction: 0,
                isTargetReached: false,
                remainingDistanceMeters: nil,
                remainingSeconds: nil
            )
        }
    }

    /// True when the current step's distance/time target has been met and there
    /// is a further step to advance to. `.open` steps never auto-advance.
    func shouldAutoAdvance(
        cumulativeDistanceMeters distance: Double,
        cumulativeElapsedSeconds elapsed: Double
    ) -> Bool {
        guard !isOnFinalStep else { return false }
        return progress(
            cumulativeDistanceMeters: distance,
            cumulativeElapsedSeconds: elapsed
        ).isTargetReached
    }

    /// Moves to the next step, anchoring its start to the supplied cumulative
    /// values. Used by both auto-advance and the manual "Next" control (early
    /// advance / stepping past an open recovery). No-op on the final step.
    mutating func advance(
        cumulativeDistanceMeters distance: Double,
        cumulativeElapsedSeconds elapsed: Double
    ) {
        guard !isOnFinalStep else { return }
        currentIndex += 1
        stepStartDistanceMeters = distance
        stepStartElapsedSeconds = elapsed
    }

    // MARK: Flattening

    static func flatten(_ structure: WorkoutStructure) -> [GuidedStep] {
        var out: [GuidedStep] = []

        out.append(step(from: structure.warmup, kind: .warmup, fallbackLabel: "Warm-up"))

        for set in structure.mainSets {
            let reps = max(1, set.repetitions)
            let multiRep = reps > 1
            for rep in 1...reps {
                out.append(step(
                    from: set.workSegment,
                    kind: .work,
                    fallbackLabel: set.label.isEmpty ? "Work" : set.label,
                    repIndex: multiRep ? rep : nil,
                    repCount: multiRep ? reps : nil
                ))

                // A recovery step is emitted only when the recovery segment
                // prescribes a real distance or time — mirroring the WorkoutKit
                // builder (``HealthKitRepository.makeCustomWorkout``). Tempo
                // blocks, whose recovery segment is empty, get no recovery step.
                let recovery = set.recoverySegment
                let hasRecovery = (recovery.durationSeconds ?? 0) > 0
                    || (recovery.distanceMeters ?? 0) > 0
                if hasRecovery {
                    out.append(step(
                        from: recovery,
                        kind: .recovery,
                        fallbackLabel: recovery.label.isEmpty ? "Recovery" : recovery.label,
                        repIndex: multiRep ? rep : nil,
                        repCount: multiRep ? reps : nil
                    ))
                }
            }
        }

        out.append(step(from: structure.cooldown, kind: .cooldown, fallbackLabel: "Cool-down"))
        return out
    }

    private static func step(
        from segment: WorkoutSegment,
        kind: GuidedStep.Kind,
        fallbackLabel: String,
        repIndex: Int? = nil,
        repCount: Int? = nil
    ) -> GuidedStep {
        // Distance takes precedence over time, matching the WorkoutKit builder's
        // goal precedence so the phone and the Watch advance on the same signal.
        let target: GuidedStep.Target
        if let distance = segment.distanceMeters, distance > 0 {
            target = .distance(meters: distance)
        } else if let duration = segment.durationSeconds, duration > 0 {
            target = .time(seconds: duration)
        } else {
            target = .open
        }
        return GuidedStep(
            kind: kind,
            label: segment.label.isEmpty ? fallbackLabel : segment.label,
            target: target,
            targetPaceSecondsPerKm: segment.targetPaceSecondsPerKm,
            repIndex: repIndex,
            repCount: repCount
        )
    }
}
