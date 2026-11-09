import Foundation

// MARK: - NextSessionUpdate

/// The coach page's "Update <next session>" button: idle, refused before it started,
/// applying, applied, or failed.
///
/// It was `isApplyingNextSessionFeedback` + `nextSessionUpdateMessage: String?` +
/// `updatedNextSessionID: UUID?`, and the caption under the button picked its colour with
/// `message.hasPrefix("Updated")` — a check on display text that a reword or a
/// translation would quietly break. Here the colour comes from the case.
///
/// ```
///          apply → refused(reason)
///   idle ───────────────────────────────▶ unavailable(reason)
///    │      apply(label)                      ok                 updated(id, label)
///    └──────────────────▶ applying(label) ──────────────────────▶
///                              │   no adaptation came back
///                              └──────────────────────────────▶ failed
/// ```
enum NextSessionUpdate: Equatable, Sendable {
    case idle
    /// Never started; `reason` says what is missing (AI Coach off, no profile, no run).
    case unavailable(String)
    /// The coach is rewriting the session named `label`.
    case applying(label: String)
    /// The session `id` was rewritten; its button stands down.
    case updated(id: UUID, label: String)
    /// The coach returned nothing usable.
    case failed

    // MARK: Reading

    var isApplying: Bool {
        if case .applying = self { return true }
        return false
    }

    /// The session already rewritten from this read, whose button no longer shows.
    var updatedSessionID: UUID? {
        guard case .updated(let id, _) = self else { return nil }
        return id
    }

    /// The caption under the button, or nil for none. The same words as before.
    var message: String? {
        switch self {
        case .idle: nil
        case .unavailable(let reason): reason
        case .applying(let label): "Updating \(label)..."
        case .updated(_, let label): "Updated \(label) in your plan."
        case .failed: "The coach feedback could not be applied. Try refreshing the AI analysis."
        }
    }

    /// The caption reads as done (green) rather than as a status (grey).
    var isSuccess: Bool { updatedSessionID != nil }
}
