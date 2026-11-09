import Foundation

// MARK: - CoachReplyStream

/// Where a streamed coach reply is: not asked for, asked with nothing written yet, or
/// partway written.
///
/// Two screens held this as a `Bool` plus a `String` set side by side —
/// `isWaitingForCoach` + `streamingReply` in the coach chat, `isLoadingAIInsight` +
/// `aiStreamBuffer` on the run's coaching read — and each had to reset both together in a
/// `defer`. Text left over with the flag off, the one combination neither screen meant,
/// cannot be written here.
///
/// ```
///          begin()            receive("…")
///   idle ──────────▶ waiting ─────────────▶ streaming(text) ──┐ receive("… more")
///    ▲                  │                       │  ▲          │
///    │      finish()    │        finish()       │  └──────────┘
///    └──────────────────┴───────────────────────┘
/// ```
///
/// The screens draw from `phase`-like reads: `waiting` is the typing dots or skeleton,
/// `streaming` is the text so far. Partials are cumulative snapshots (see
/// `OnDeviceCoachGenerating`), so `receive` replaces the text rather than appending.
enum CoachReplyStream: Equatable, Sendable {
    /// Nothing asked, or the last reply has landed.
    case idle
    /// Asked; the model has not written a word yet.
    case waiting
    /// The reply so far — everything written up to now, never empty.
    case streaming(String)

    // MARK: Reading

    /// True from `begin()` until `finish()`: what disables Send and Rewrite.
    var isActive: Bool { self != .idle }

    /// The reply written so far; empty unless streaming.
    var partialText: String {
        guard case .streaming(let text) = self else { return "" }
        return text
    }

    // MARK: Transitions

    /// The request has gone out.
    mutating func begin() {
        self = .waiting
    }

    /// The model's latest cumulative partial. An empty partial reads as still waiting, as
    /// it did when the screens checked `buffer.isEmpty`. Ignored once `finish()` has run.
    mutating func receive(_ text: String) {
        guard isActive else { return }
        self = text.isEmpty ? .waiting : .streaming(text)
    }

    /// The reply has landed or failed; the screen shows the result in its own state.
    mutating func finish() {
        self = .idle
    }
}
