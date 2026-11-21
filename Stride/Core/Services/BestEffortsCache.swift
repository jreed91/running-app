import Foundation

// MARK: - BestEffortsCache

/// Every run's best efforts, worked out once and kept for the rest of the session.
///
/// Before this, Progress and every run screen decoded each run's distance series and
/// slid the windows over it again each time they appeared. That is hundreds of runs of
/// a few thousand readings each. The cache works out a run only when it is new, or when
/// its series has changed size (a late backfill, an edit), and hands back the rest as
/// they were. Progress's card and the run screen's card share it.
///
/// An actor, so the work runs off the main actor, and two cards asking at once don't
/// work out the same run twice.
actor BestEffortsCache {
    static let shared = BestEffortsCache()

    /// A run as the cache needs it, read from the model on the main actor.
    struct Input: Sendable, Equatable {
        let id: UUID
        let date: Date
        let series: Data
    }

    private struct Entry {
        let seriesSize: Int
        let date: Date
        /// `nil` for a run too short for any effort, so it isn't worked out again.
        let efforts: BestEfforts.RunEfforts?
    }

    private var entries: [UUID: Entry] = [:]

    /// How many runs have been worked out from their series so far. For tests.
    private(set) var computed = 0

    /// The best efforts of every run in `inputs` that has any, in the order given.
    /// Runs no longer passed in are dropped, so a deleted run's record goes with it.
    func efforts(for inputs: [Input]) -> [BestEfforts.RunEfforts] {
        var kept: [UUID: Entry] = [:]
        kept.reserveCapacity(inputs.count)
        var result: [BestEfforts.RunEfforts] = []
        for input in inputs {
            let entry: Entry
            if let cached = entries[input.id], cached.seriesSize == input.series.count, cached.date == input.date {
                entry = cached
            } else {
                entry = Entry(seriesSize: input.series.count, date: input.date, efforts: Self.work(input))
                computed += 1
            }
            kept[input.id] = entry
            if let efforts = entry.efforts { result.append(efforts) }
        }
        entries = kept
        return result
    }

    private static func work(_ input: Input) -> BestEfforts.RunEfforts? {
        guard let points = try? JSONDecoder().decode([SplitBucketing.DistancePoint].self, from: input.series) else {
            return nil
        }
        let samples = points.map { BestEfforts.Sample(elapsedSeconds: $0.elapsedSeconds, meters: $0.cumulativeMeters) }
        let efforts = BestEfforts.efforts(in: samples)
        guard !efforts.isEmpty else { return nil }
        return BestEfforts.RunEfforts(id: input.id, date: input.date, efforts: efforts)
    }
}
