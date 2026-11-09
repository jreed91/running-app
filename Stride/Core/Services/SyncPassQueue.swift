import Foundation

// MARK: - SyncPassQueue

/// Whether a HealthKit import pass is running, and whether another trigger is waiting
/// behind it.
///
/// `WorkoutSyncService` held this as `isSyncing` plus `pendingSyncSource`, written in
/// three places. A trigger that lands mid-pass must not be dropped (M1): the running pass
/// took its snapshot of stored ids before the workout that fired the trigger existed. So
/// at most one follow-up is queued, and the latest trigger names it.
///
/// ```
///           request(a) → run a
///   idle ─────────────────────▶ syncing(queued: nil)
///    ▲                            │   ▲        │ request(b) → queued
///    │ next() → nil               │   │        ▼
///    └────────────────────────────┘   └── syncing(queued: b) ── request(c) → queued (c replaces b)
///                                    next() → b
/// ```
///
/// Only the source label is queued. The follow-up pass reuses the look-back window of the
/// call that started the loop, as it always has; see `WorkoutSyncService.handleNewWorkoutsDetected`.
enum SyncPassQueue: Equatable, Sendable {
    /// No pass running.
    case idle
    /// A pass is running; `queued` is the source of the one follow-up owed, if any.
    case syncing(queued: String?)

    /// The source of the follow-up pass owed, if one is queued.
    var queuedSource: String? {
        guard case .syncing(let queued) = self else { return nil }
        return queued
    }

    /// A trigger from `source` arrived. Returns true when the caller should run the pass
    /// now; false when one is already running and this trigger has been queued behind it.
    mutating func request(_ source: String) -> Bool {
        switch self {
        case .idle:
            self = .syncing(queued: nil)
            return true
        case .syncing:
            self = .syncing(queued: source)
            return false
        }
    }

    /// The running pass finished. Returns the queued source to run next, still holding the
    /// queue busy, or nil once nothing is owed and the queue is idle again.
    mutating func next() -> String? {
        guard case .syncing(let queued) = self else { return nil }
        guard let queued else {
            self = .idle
            return nil
        }
        self = .syncing(queued: nil)
        return queued
    }
}
