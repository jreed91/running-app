import Foundation

// MARK: - WatchAutoPause

/// Pauses a run on the Watch when the runner stops, and resumes it when they move off
/// again (Watch runs, PR 6b), the way Apple's Workout app does at a crossing.
///
/// Fed each GPS fix's speed. A few seconds below walking-to-a-stop speed pauses; a few
/// seconds back above a slow jog resumes. The gap between the two speeds and the hold
/// times keep it from flickering at a slow shuffle. It only ever resumes a pause it made
/// itself: a runner who paused by hand resumes by hand.
///
/// Off for plan sessions with steps, because a paused workout's clock stops, and a timed
/// recovery spent standing would then never end.
///
/// Compiled into the app and `StrideWatch`, Foundation only, and tested in `StrideCoreTests` (`swift test`).
public struct WatchAutoPause: Equatable, Sendable {

    public enum Action: Equatable, Sendable {
        case pause
        case resume
    }

    /// Below this, in metres per second, the runner is standing or walking to a stop.
    /// The phone's tracker stops counting distance at the same speed.
    public static let stopSpeed: Double = 0.5
    /// Above this the runner is moving again: a slow jog, not a step or two at a light.
    public static let moveSpeed: Double = 1.0
    public static let stopSeconds: TimeInterval = 6
    public static let moveSeconds: TimeInterval = 3

    /// The run is paused because of this, not because the runner tapped Pause.
    public private(set) var isAutoPaused = false
    private var slowSince: Date?
    private var fastSince: Date?

    public init() {}

    /// What to do for a fix with `speed` (CoreLocation's, negative when unknown) at `date`.
    /// - Parameter isRunning: the workout is running, not paused by hand or saving.
    public mutating func update(speed: Double, at date: Date, isRunning: Bool) -> Action? {
        guard speed >= 0 else { return nil }
        if isAutoPaused {
            guard speed >= Self.moveSpeed else {
                fastSince = nil
                return nil
            }
            let since = fastSince ?? date
            fastSince = since
            guard date.timeIntervalSince(since) >= Self.moveSeconds else { return nil }
            reset()
            return .resume
        }
        guard isRunning, speed < Self.stopSpeed else {
            slowSince = nil
            return nil
        }
        let since = slowSince ?? date
        slowSince = since
        guard date.timeIntervalSince(since) >= Self.stopSeconds else { return nil }
        slowSince = nil
        isAutoPaused = true
        return .pause
    }

    /// Forgets any auto-pause, when the runner pauses or resumes by hand.
    public mutating func reset() {
        isAutoPaused = false
        slowSince = nil
        fastSince = nil
    }
}
