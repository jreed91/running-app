import Foundation

// MARK: - RestTimerState

/// The strength session's rest between sets, as one value.
///
/// It used to be four `@State` variables on `StrengthActiveView` — `restTimerActive`,
/// `restTimeRemaining`, `restDeadline` and `restTotalSeconds` — that every transition had
/// to set together. Nothing stopped "active with no deadline" or "inactive with time
/// left"; the code just never wrote them. Here those states cannot be spelled.
///
/// ```
///            start                tick (time left)
///   idle ────────────▶ resting ◀──────────────┐
///    ▲                   │  │                 │
///    │   tick reaches 0  │  └─────────────────┘
///    ├───────────────────┤      adjust(by:) moves the deadline
///    │   adjust to 0     │
///    └───────────────────┘
///        end (Skip rest, leaving the screen)
/// ```
///
/// Pure and clock-free: every transition takes `now`, so `RestTimerStateTests` pins each
/// one. The view owns the `Task` that ticks it once a second, and the per-exercise rest
/// length (`restSeconds`) that `start` is handed.
enum RestTimerState: Equatable, Sendable {
    /// No rest running; the set-logging card shows.
    case idle
    /// Counting down to `deadline`; the rest card shows.
    case resting(Rest)

    struct Rest: Equatable, Sendable {
        /// When the rest ends. The countdown is derived from this, not decremented, so a
        /// phone locked between sets resumes on the true time left (M27, `RestCountdown`).
        var deadline: Date
        /// Whole seconds left as of the last tick or adjustment; what the ring shows.
        var remainingSeconds: Int
        /// The rest's full length including adjustments, for the ring's progress.
        var totalSeconds: Int
    }

    // MARK: Reading

    var isResting: Bool {
        if case .resting = self { return true }
        return false
    }

    /// Seconds left on the ring; 0 when idle. The rest-over haptic fires on this going
    /// from 1 to 0, which both a natural finish and "Skip rest" with one second left do —
    /// as they did when this was a stored `Int`.
    var remainingSeconds: Int {
        guard case .resting(let rest) = self else { return 0 }
        return rest.remainingSeconds
    }

    /// How far round the ring is, 0...1. A full ring when idle (never drawn).
    var progress: Double {
        guard case .resting(let rest) = self, rest.totalSeconds > 0 else { return 1 }
        let elapsed = Double(rest.totalSeconds - rest.remainingSeconds)
        return min(1, max(0, elapsed / Double(rest.totalSeconds)))
    }

    // MARK: Transitions

    /// A fresh rest of `seconds`, replacing any rest already running.
    static func start(seconds: Int, now: Date) -> RestTimerState {
        .resting(Rest(
            deadline: now.addingTimeInterval(TimeInterval(seconds)),
            remainingSeconds: seconds,
            totalSeconds: seconds
        ))
    }

    /// Re-reads the time left from the deadline. Reaching 0 ends the rest.
    mutating func tick(now: Date) {
        guard case .resting(var rest) = self else { return }
        rest.remainingSeconds = RestCountdown.secondsRemaining(deadline: rest.deadline, now: now)
        self = rest.remainingSeconds <= 0 ? .idle : .resting(rest)
    }

    /// Moves the running rest by `seconds` (negative shortens it). Shortening it to
    /// nothing ends it. Does nothing when idle; returns whether a rest was moved, so the
    /// caller only carries the change to the exercise's next rests when one was.
    @discardableResult
    mutating func adjust(by seconds: Int, now: Date) -> Bool {
        guard case .resting(var rest) = self else { return false }
        let remaining = RestCountdown.secondsRemaining(deadline: rest.deadline, now: now)
        let newRemaining = max(0, remaining + seconds)
        rest.deadline = now.addingTimeInterval(TimeInterval(newRemaining))
        rest.remainingSeconds = newRemaining
        rest.totalSeconds = max(1, rest.totalSeconds + seconds)
        self = newRemaining == 0 ? .idle : .resting(rest)
        return true
    }

    /// Ends the rest early, or does nothing when idle.
    mutating func end() {
        self = .idle
    }
}
