import Foundation

// MARK: - RestCountdown

/// Deadline-based countdown for the strength-session rest timer.
///
/// The rest timer previously decremented a stored counter once per `Task`
/// tick, so the countdown froze whenever the process was suspended (a
/// locked phone between sets has no background keep-alive) and resumed
/// showing more time left than had actually elapsed (M27). Deriving the
/// remaining seconds from a fixed deadline keeps it wall-clock accurate: a
/// backgrounded phone resumes showing the true remaining time. Every method
/// takes an explicit `Date` so the type is fully deterministic under test.
enum RestCountdown {

    /// Whole seconds remaining until `deadline` as of `now` (never negative).
    ///
    /// Rounds up so a countdown started at 60 s still reads "60" on the first
    /// tick and only reaches 0 once the deadline has actually passed.
    static func secondsRemaining(deadline: Date, now: Date) -> Int {
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return Int(remaining.rounded(.up))
    }
}
