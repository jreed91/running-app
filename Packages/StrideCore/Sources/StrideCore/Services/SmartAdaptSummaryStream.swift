import Foundation

// MARK: - SmartAdaptSummaryStream

/// Reads the coach's per-workout explanations out of a **partial** plan adaptation while
/// it is still streaming in.
///
/// This used to be a character-level JSON scanner. It had to be: the cloud path streamed
/// raw JSON text, and `JSONDecoder` cannot help until the last byte lands, by which point
/// there is nothing left to stream. Guided generation removed the problem rather than
/// solving it — `FoundationModelsCoachBackend` streams typed snapshots and publishes the
/// explanations that are *finished*, one per line — so what arrives here is prose, and
/// the scanner had nothing left to scan. It sat looking for a `"summary"` key that the
/// on-device path never emits, which is why Smart Adapt showed "Reading coach summary…"
/// for the whole run (N30).
///
/// It stays a named type rather than an inline `split`: the display limit belongs with
/// the rule that produces the list, and `PlanTabView` is not where either wants to live
/// (D1).
enum SmartAdaptSummaryStream {

    /// Every completed explanation in `text`, in the order the coach wrote them.
    ///
    /// Returns an empty array while nothing has been completed yet, which the caller
    /// shows as "reading coach summary…" rather than as an empty result.
    static func summaries(in text: String) -> [String] {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// How many of the most recent summaries the progress card shows at once.
    static let displayLimit = 4
}
