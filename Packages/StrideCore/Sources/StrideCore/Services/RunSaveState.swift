import Foundation

// MARK: - RunSaveState

/// A finished run on its way into the store, from the Finish dialog until it is saved or
/// thrown away.
///
/// `WorkoutTrackerService.finishWorkout()` is one-shot, so once a run is finished it
/// exists only in memory until `context.save()` succeeds (N15). `ActiveRunView` held it
/// as `pendingSave: RunWorkout?` beside `saveErrorMessage: String?`, set and cleared by
/// hand in five places; "an error showing with no run held" was writable and would have
/// offered Try Again on nothing. Here the message only exists with the run it is about.
///
/// ```
///             hold(run)                  fail(run, message)
///   unsaved ────────────▶ held(run) ─────────────────────────▶ failed(run, message)
///      ▲                    │   ▲                                 │      │
///      │      clear()       │   └──── retry() / dismissError() ───┘      │
///      └────────────────────┴────────────────────────────────────────────┘
///            saved, or discarded                     clear() (Discard)
/// ```
///
/// Generic over the run so the transitions are tested with plain values, without a
/// SwiftData container; the app uses `RunSaveState<RunWorkout>`.
public enum RunSaveState<Run> {
    /// Nothing finished and unsaved: recording, or the run is already in the store.
    case unsaved
    /// Finished and handed to the save; retried from here rather than re-finishing the
    /// tracker, which would return nil.
    case held(Run)
    /// The save failed. The alert shows `message` and offers Try Again or Discard.
    case failed(Run, message: String)

    // MARK: Reading

    /// The finished run not yet in the store, if any.
    public var heldRun: Run? {
        switch self {
        case .unsaved: nil
        case .held(let run), .failed(let run, _): run
        }
    }

    /// What the "Couldn't save your run" alert says; nil when it should not show.
    public var errorMessage: String? {
        guard case .failed(_, let message) = self else { return nil }
        return message
    }

    // MARK: Transitions

    /// The run is finished and about to be saved.
    public mutating func hold(_ run: Run) {
        self = .held(run)
    }

    /// Saving `run` failed with `message`.
    public mutating func fail(_ run: Run, message: String) {
        self = .failed(run, message: message)
    }

    /// The alert went away without a choice. The run stays held.
    public mutating func dismissError() {
        guard case .failed(let run, _) = self else { return }
        self = .held(run)
    }

    /// Try Again: clears the error and hands back the run to save, or nil when none is
    /// held.
    public mutating func retry() -> Run? {
        dismissError()
        return heldRun
    }

    /// Saved, or discarded: nothing is held any more.
    public mutating func clear() {
        self = .unsaved
    }
}

extension RunSaveState: Equatable where Run: Equatable {}
