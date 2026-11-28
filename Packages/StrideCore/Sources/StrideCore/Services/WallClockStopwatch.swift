import Foundation

// MARK: - WallClockStopwatch

/// Wall-clock elapsed-time accumulator for a run session.
///
/// The active-run tracker previously counted `+1` per `Timer` fire, which
/// silently undercounts whenever the process is suspended (a locked-phone
/// treadmill run has no background keep-alive) or the run loop stalls —
/// corrupting duration, pace, and every downstream VDOT analytic. This value
/// type instead derives elapsed time from timestamps, so a suspended process
/// resumes with the correct total.
///
/// Time only accrues while running. `pause` banks the current segment into
/// `accumulated`; `resume` opens a new segment; the gap in between is not
/// counted. Every method takes an explicit `Date` so the type is fully
/// deterministic under test.
public struct WallClockStopwatch: Equatable, Sendable {

    /// Seconds banked from previously completed active segments.
    public private(set) var accumulated: TimeInterval = 0
    /// Start of the currently running segment, or `nil` while paused/stopped.
    public private(set) var segmentStart: Date?

    public var isRunning: Bool { segmentStart != nil }

    /// Begins timing from `date`, discarding any prior state.
    public mutating func start(at date: Date) {
        accumulated = 0
        segmentStart = date
    }

    /// Banks the running segment and stops accruing time. No-op if not running.
    public mutating func pause(at date: Date) {
        guard let start = segmentStart else { return }
        accumulated += max(0, date.timeIntervalSince(start))
        segmentStart = nil
    }

    /// Opens a new active segment from `date`. No-op if already running.
    public mutating func resume(at date: Date) {
        guard segmentStart == nil else { return }
        segmentStart = date
    }

    /// Total elapsed seconds as of `date` (banked plus the live segment).
    public func elapsed(at date: Date) -> TimeInterval {
        guard let start = segmentStart else { return accumulated }
        return accumulated + max(0, date.timeIntervalSince(start))
    }

    /// Returns to the zeroed, stopped state.
    public mutating func reset() {
        accumulated = 0
        segmentStart = nil
    }

    public init(
        accumulated: TimeInterval = 0,
        segmentStart: Date? = nil
    ) {
        self.accumulated = accumulated
        self.segmentStart = segmentStart
    }
}
