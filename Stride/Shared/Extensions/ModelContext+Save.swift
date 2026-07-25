import Foundation
import SwiftData

extension ModelContext {

    /// Saves the context, logging rather than throwing when the write fails (D5).
    ///
    /// The app had 35 bare `try? context.save()` calls. Most of them are genuinely
    /// best-effort — a preference toggle, a cached insight, a weather snapshot — and
    /// making them all `throws` would push error handling into view bodies that have
    /// nothing useful to do with it. The problem was never that they don't propagate;
    /// it is that they were **silent**. A store that has started rejecting writes
    /// (disk full, a CloudKit schema mismatch, a validation failure on one bad model)
    /// looked exactly like a store that was working, from the user's side *and* from
    /// Pulse. Every symptom — settings that revert, a run that loses its weather, a
    /// plan edit that doesn't stick — arrived with no trace of the cause.
    ///
    /// This keeps the best-effort semantics and adds the trace. Failures that must
    /// reach the user still use `do`/`catch` at the call site: the run-finish save
    /// (N15) raises an alert with Try Again, and the plan-recovery mutations surface
    /// their error on the dashboard.
    ///
    /// - Parameters:
    ///   - operation: What was being saved, in a few words — this is the log line, so
    ///     make it identify the call site ("plan run days", "reset all data").
    ///   - label: Log category, defaulting to the subsystem-wide SwiftData one.
    /// - Returns: `true` when the store is consistent with memory afterwards, which
    ///   includes the case where there was nothing to write.
    @discardableResult
    func saveOrLog(_ operation: String, label: String = "swiftdata") -> Bool {
        guard hasChanges else { return true }
        do {
            try save()
            return true
        } catch {
            AppLogger.log(
                "Save failed while persisting \(operation): \(error)",
                label: label,
                level: .error
            )
            return false
        }
    }
}
