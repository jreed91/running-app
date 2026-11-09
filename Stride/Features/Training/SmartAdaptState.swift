import Foundation

// MARK: - SmartAdaptState

/// Smart Adapt on the Plan tab: not run, running with its progress, or finished with what
/// happened.
///
/// It was `isAdaptingPlan: Bool` beside a `SmartAdaptProgress`, and the card drew the
/// progress only while the Bool was true. Every outcome message was written in the last
/// moments of the run — "Plan updated and synced.", "The coach response could not be
/// applied…" — and the Bool went false in the same `defer`, so the card hid the panel
/// before the runner could read either. A failed adapt looked exactly like nothing
/// happening. `finished` keeps the outcome on the card until the next run.
///
/// ```
///           start()                 finish(message:)
///   idle ───────────▶ running(p) ──────────────────────▶ finished(p)
///    ▲                   │  ▲                                 │
///    │ stopIfRunning()   │  └────────── start() ──────────────┘
///    └───────────────────┘
///   (the tab was left, or the plan was replaced mid-run)
/// ```
enum SmartAdaptState: Equatable {
    case idle
    case running(SmartAdaptProgress)
    case finished(SmartAdaptProgress)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// The progress the card draws: live while running, the outcome once finished, and
    /// `.idle` (nothing) otherwise. Writes land only while running, so a late partial
    /// from the coach cannot repaint a finished card.
    var progress: SmartAdaptProgress {
        get {
            switch self {
            case .idle: .idle
            case .running(let progress), .finished(let progress): progress
            }
        }
        set {
            guard isRunning else { return }
            self = .running(newValue)
        }
    }

    /// Whether the card shows a progress panel at all.
    var showsProgress: Bool { self != .idle }

    // MARK: Transitions

    /// A new run, replacing whatever the last one left on the card.
    mutating func start() {
        self = .running(.starting)
    }

    /// The run reached an outcome the runner should read: it stays on the card.
    mutating func finish(message: String) {
        guard case .running(var progress) = self else { return }
        progress.currentMessage = message
        self = .finished(progress)
    }

    /// The run was abandoned without an outcome (the tab was left, the plan replaced):
    /// clear the card, as it always was.
    mutating func stopIfRunning() {
        guard isRunning else { return }
        self = .idle
    }
}

// MARK: - SmartAdaptProgress

/// What one Smart Adapt run has done so far.
struct SmartAdaptProgress: Equatable {
    struct Update: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    var currentMessage: String
    var completedCount: Int
    var totalCount: Int
    var updates: [Update]
    var streamingSummaries: [String] = []

    static let idle = SmartAdaptProgress(currentMessage: "", completedCount: 0, totalCount: 0, updates: [])
    static let starting = SmartAdaptProgress(currentMessage: "Preparing plan...", completedCount: 0, totalCount: 0, updates: [])

    var fractionCompleted: Double? {
        guard totalCount > 0 else { return nil }
        return Double(completedCount) / Double(totalCount)
    }
}
