import SwiftUI
import WidgetKit

// MARK: - StrideWidgetEntry

/// One rendering of the snapshot, at one moment.
struct StrideWidgetEntry: TimelineEntry {

    /// Where the content came from — which is a presentation decision, not a diagnostic.
    /// All three of the non-live cases end in the same card (see ``WidgetEmptyState``),
    /// so resolving them once here keeps four widgets from each deciding it again.
    enum Source: Equatable {
        /// The runner's own data, current as of `date`.
        case live
        /// The gallery preview and SwiftUI previews — plausible data, nobody's real week.
        case sample
        /// Nothing to show: the app has not written a snapshot yet, the App Group is not
        /// reachable, or what is on disk is too old to present as current.
        case unavailable
    }

    let date: Date
    let snapshot: WidgetSnapshot
    let source: Source
}

// MARK: - StrideSnapshotProvider

/// Feeds every Stride widget from the one snapshot the app writes into the shared App
/// Group (B1).
///
/// The provider does no work beyond reading a file, because there is nothing else it
/// *can* do: the extension has no access to the SwiftData store, so the app has already
/// decided everything except how the passage of time reads. That exception is the reason
/// the timeline has more than one entry — see ``timeline(from:)``.
struct StrideSnapshotProvider: TimelineProvider {

    /// How many midnights ahead the timeline pre-renders. Four days of entries means a
    /// phone that never opens Stride still turns "Tomorrow" into "Today" on time, and
    /// still counts the race down, without spending a reload to do it.
    private static let daysAhead = 4

    private let store: WidgetSnapshotStore

    init(store: WidgetSnapshotStore = .shared) {
        self.store = store
    }

    // MARK: TimelineProvider

    func placeholder(in context: Context) -> StrideWidgetEntry {
        let now = Date()
        return StrideWidgetEntry(date: now, snapshot: .sample(now: now), source: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (StrideWidgetEntry) -> Void) {
        let now = Date()
        // The widget gallery renders every widget before the user has picked one, and an
        // empty card there is a widget nobody adds.
        guard !context.isPreview else {
            completion(StrideWidgetEntry(date: now, snapshot: .sample(now: now), source: .sample))
            return
        }
        completion(entry(at: now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StrideWidgetEntry>) -> Void) {
        completion(timeline(from: Date()))
    }

    // MARK: Timeline

    /// One entry now, then one at each of the next few midnights.
    ///
    /// Everything in the snapshot is fixed the moment the app writes it *except* how the
    /// dates in it read: "Tomorrow" becomes "Today", a countdown loses a day. Those are
    /// derived from the entry's own date (``WidgetRelativeDay``), so pre-rendering the
    /// midnights is what keeps them right — the app is not running at 00:00 to push a
    /// correction, and asking WidgetKit for a reload then would spend budget on data that
    /// has not actually changed.
    func timeline(from now: Date, calendar: Calendar = .current) -> Timeline<StrideWidgetEntry> {
        var entries = [entry(at: now)]
        var day = calendar.startOfDay(for: now)

        for _ in 0..<Self.daysAhead {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            entries.append(entry(at: day))
        }

        // Ask for a fresh timeline once the last entry is in the past. In practice the app
        // beats this to it on the next launch, run, or plan change.
        return Timeline(entries: entries, policy: .after(day))
    }

    /// Reads the snapshot and decides whether it is still worth presenting as current.
    ///
    /// A snapshot too old to trust degrades to the empty state rather than being shown
    /// with a caveat: a widget is a glance, and a stale week's mileage read at a glance is
    /// simply a wrong number — worse than a card that says to open the app.
    func entry(at date: Date) -> StrideWidgetEntry {
        guard let snapshot = store.load(), !snapshot.isStale(asOf: date) else {
            return StrideWidgetEntry(date: date, snapshot: .empty(generatedAt: date), source: .unavailable)
        }
        return StrideWidgetEntry(date: date, snapshot: snapshot, source: .live)
    }
}
