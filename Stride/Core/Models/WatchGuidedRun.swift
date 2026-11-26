import Foundation

// MARK: - WatchGuidedRun

/// A plan session's steps as the Watch runs them (Watch runs, PR 3): which step the runner
/// is on, how much of it is left, and whether they are on pace for it.
///
/// A thin layer over the phone's own ``GuidedWorkoutState``, so the Watch steps through a
/// session on exactly the same rules: distance before time, no recovery after the last
/// rep, open steps advanced by hand. What it adds is what the phone's HUD and
/// `RunSpokenCues` do around that state: auto-advancing as the run's numbers arrive, and
/// the text and pace check the Watch's small screen needs.
///
/// Compiled into the app and `StrideWatch`, Foundation only, and tested in `StrideTests`.
struct WatchGuidedRun: Equatable, Sendable {

    private(set) var state: GuidedWorkoutState

    init(state: GuidedWorkoutState) {
        self.state = state
    }

    init?(session: WatchRunSession) {
        guard let state = session.guidedState() else { return nil }
        self.init(state: state)
    }

    var currentStep: GuidedStep { state.currentStep }
    var nextStep: GuidedStep? { state.nextStep }
    var isOnFinalStep: Bool { state.isOnFinalStep }

    // MARK: Stepping

    /// Moves on when `metrics` reaches the current step's target, and returns how many steps
    /// it moved (0 or 1 in practice: each step starts at the reading that ended the last).
    /// The loop is a guard against a zero-length step, which the flattener never emits.
    @discardableResult
    mutating func update(with metrics: WatchRunMetrics) -> Int {
        var moved = 0
        while state.shouldAutoAdvance(
            cumulativeDistanceMeters: metrics.distanceMeters,
            cumulativeElapsedSeconds: metrics.elapsedSeconds
        ), moved < state.stepCount {
            state.advance(
                cumulativeDistanceMeters: metrics.distanceMeters,
                cumulativeElapsedSeconds: metrics.elapsedSeconds
            )
            moved += 1
        }
        return moved
    }

    /// The runner's own "next", for an open step or to cut one short. `false` on the last.
    @discardableResult
    mutating func skip(with metrics: WatchRunMetrics) -> Bool {
        guard !state.isOnFinalStep else { return false }
        state.advance(
            cumulativeDistanceMeters: metrics.distanceMeters,
            cumulativeElapsedSeconds: metrics.elapsedSeconds
        )
        return true
    }

    func progress(with metrics: WatchRunMetrics) -> GuidedStepProgress {
        state.progress(
            cumulativeDistanceMeters: metrics.distanceMeters,
            cumulativeElapsedSeconds: metrics.elapsedSeconds
        )
    }

    // MARK: Text

    /// "Warm-up", or "VO2max Intervals 3/6" on a repeat.
    var stepTitle: String {
        let step = state.currentStep
        if let index = step.repIndex, let count = step.repCount {
            return "\(step.label) \(index)/\(count)"
        }
        return step.label
    }

    /// "4/14": the step number out of the session's steps.
    var stepPosition: String { "\(state.stepNumber)/\(state.stepCount)" }

    /// "0.42 km" or "1:30" left in the step, or `nil` for an open step.
    func remainingText(with metrics: WatchRunMetrics, metric: Bool) -> String? {
        let current = progress(with: metrics)
        if let meters = current.remainingDistanceMeters {
            let distance = WatchRunMetrics.distanceText(meters, metric: metric)
            return "\(distance) \(WatchRunMetrics.distanceUnit(metric: metric))"
        }
        if let seconds = current.remainingSeconds {
            return WatchRunMetrics.elapsedText(seconds.rounded(.up))
        }
        return nil
    }

    // MARK: Pace

    enum PaceStatus: Equatable, Sendable {
        case tooFast, onPace, tooSlow
    }

    /// Seconds per kilometre either side of a step's target pace that still counts as on
    /// pace. About the width of the phone plan's own pace bands at 5K pace.
    static let paceToleranceSecondsPerKm: Double = 10

    /// How the current pace compares with the step's target, or `nil` when the step has
    /// no target pace or there is no current pace to compare.
    func paceStatus(with metrics: WatchRunMetrics) -> PaceStatus? {
        guard let target = state.currentStep.targetPaceSecondsPerKm, target > 0,
              let pace = metrics.currentPaceSecondsPerKm else { return nil }
        if pace < target - Self.paceToleranceSecondsPerKm { return .tooFast }
        if pace > target + Self.paceToleranceSecondsPerKm { return .tooSlow }
        return .onPace
    }
}
