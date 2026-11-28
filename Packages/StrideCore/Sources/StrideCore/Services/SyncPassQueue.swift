import Foundation

// MARK: - SyncPassQueue

/// Whether a HealthKit import pass is running, and whether another trigger is waiting
/// behind it.
///
/// `WorkoutSyncService` held this as `isSyncing` plus `pendingSyncSource`, written in
/// three places. A trigger that lands mid-pass must not be dropped (M1): the running pass
/// took its snapshot of stored ids before the workout that fired the trigger existed. So
/// at most one follow-up is queued. It carries the latest trigger's source and the widest
/// look-back window any queued trigger asked for.
///
/// ```
///           request(a) → run a
///   idle ─────────────────────▶ syncing(queued: nil)
///    ▲                            │   ▲        │ request(b) → queued
///    │ next() → nil               │   │        ▼
///    └────────────────────────────┘   └── syncing(queued: b) ── request(c) → queued (b ∪ c)
///                                    next() → b
/// ```
///
/// The window used to be dropped: only the source was queued, and the follow-up reused the
/// window of the call that started the loop. So History's 60-day pull, opened while the
/// launch sync was running, ran with the 7-day default.
public enum SyncPassQueue: Equatable, Sendable {
    /// No pass running.
    case idle
    /// A pass is running; `queued` is the one follow-up owed, if any.
    case syncing(queued: Request?)

    /// One import pass to run: who asked, and how far back they asked to look (`nil` is
    /// the service's default window).
    public struct Request: Equatable, Sendable {
        public var source: String
        public var lookbackDays: Int?

        public init(source: String, lookbackDays: Int? = nil) {
            self.source = source
            self.lookbackDays = lookbackDays
        }

        /// `other`'s source, with the wider of the two windows, so folding several
        /// triggers into one follow-up never narrows what any of them asked for.
        public func merged(with other: Request) -> Request {
            let widest: Int? = switch (lookbackDays, other.lookbackDays) {
            case let (mine?, theirs?): max(mine, theirs)
            case let (mine?, nil): mine
            case let (nil, theirs): theirs
            }
            return Request(source: other.source, lookbackDays: widest)
        }
    }

    /// The follow-up pass owed, if one is queued.
    public var queued: Request? {
        guard case .syncing(let queued) = self else { return nil }
        return queued
    }

    /// The source of the follow-up pass owed, if one is queued.
    public var queuedSource: String? { queued?.source }

    /// A trigger arrived. Returns true when the caller should run the pass now; false when
    /// one is already running and this trigger has been folded into the follow-up.
    public mutating func request(_ request: Request) -> Bool {
        switch self {
        case .idle:
            self = .syncing(queued: nil)
            return true
        case .syncing(let queued):
            self = .syncing(queued: queued.map { $0.merged(with: request) } ?? request)
            return false
        }
    }

    /// The running pass finished. Returns the follow-up to run next, still holding the
    /// queue busy, or nil once nothing is owed and the queue is idle again.
    public mutating func next() -> Request? {
        guard case .syncing(let queued) = self else { return nil }
        guard let queued else {
            self = .idle
            return nil
        }
        self = .syncing(queued: nil)
        return queued
    }
}
