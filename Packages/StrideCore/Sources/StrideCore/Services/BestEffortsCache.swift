import Foundation

// MARK: - BestEffortsCache

/// Every run's best efforts, worked out once and kept: for the session, and on disk
/// between launches.
///
/// Before this, Progress and every run screen decoded each run's distance series and
/// slid the windows over it again each time they appeared. That is hundreds of runs of
/// a few thousand readings each. The cache works out a run only when it is new, and
/// hands back the rest as they were. Progress's card and the run screen's card share it.
///
/// Reading the series was the other half of the cost: a card that handed over every
/// run's series to ask for its efforts read every series from the store first, even when
/// all of them were already worked out. So a card first asks which runs are ``missing``,
/// by id and date alone, and reads the series of only those. After the first time,
/// that is none.
///
/// An actor, so the work runs off the main actor, and two cards asking at once don't
/// work out the same run twice.
public actor BestEffortsCache {
    public static let shared = BestEffortsCache(storeURL: defaultStoreURL)

    /// A run as the cache knows it without its series: enough to tell whether its
    /// efforts are already worked out.
    public struct Key: Sendable, Hashable {
        public let id: UUID
        public let date: Date

        public init(
            id: UUID,
            date: Date
        ) {
            self.id = id
            self.date = date
        }
    }

    /// A run with its series, read from the model on the main actor.
    public struct Input: Sendable, Equatable {
        public let id: UUID
        public let date: Date
        public let series: Data

        public var key: Key { Key(id: id, date: date) }

        public init(
            id: UUID,
            date: Date,
            series: Data
        ) {
            self.id = id
            self.date = date
            self.series = series
        }
    }

    private struct Entry: Codable {
        public let date: Date
        /// `nil` when unknown, for an entry read back from disk.
        public let seriesSize: Int?
        /// `nil` for a run too short for any effort, so it isn't worked out again.
        public let efforts: [BestEfforts.Distance: Double]?
    }

    private let storeURL: URL?
    private var entries: [UUID: Entry] = [:]
    private var hasLoaded = false

    /// How many runs have been worked out from their series so far. For tests.
    public private(set) var computed = 0

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL
    }

    // MARK: Asking by key

    /// The runs among `keys` whose efforts aren't known yet: new runs, and runs whose
    /// date changed. Only these need their series read.
    public func missing(_ keys: [Key]) -> [UUID] {
        loadIfNeeded()
        return keys.compactMap { key in entries[key.id]?.date == key.date ? nil : key.id }
    }

    /// The best efforts of every run in `keys` that has any, in the order given, after
    /// working out `adding` (the series of the runs ``missing`` named). Runs no longer
    /// in `keys` are dropped, so a deleted run's record goes with it.
    public func efforts(for keys: [Key], adding inputs: [Input]) -> [BestEfforts.RunEfforts] {
        loadIfNeeded()
        for input in inputs {
            entries[input.id] = Entry(date: input.date, seriesSize: input.series.count, efforts: Self.work(input))
            computed += 1
        }
        let wanted = Set(keys.map(\.id))
        let before = entries.count
        entries = entries.filter { wanted.contains($0.key) }
        if !inputs.isEmpty || entries.count != before { save() }
        return keys.compactMap { key in
            guard let entry = entries[key.id], entry.date == key.date, let efforts = entry.efforts else { return nil }
            return BestEfforts.RunEfforts(id: key.id, date: key.date, efforts: efforts)
        }
    }

    // MARK: Asking with every series

    /// The best efforts of every run in `inputs` that has any, in the order given.
    /// Works out a run again when its series changed size.
    public func efforts(for inputs: [Input]) -> [BestEfforts.RunEfforts] {
        loadIfNeeded()
        let stale = inputs.filter { input in
            guard let entry = entries[input.id], entry.date == input.date else { return true }
            return entry.seriesSize.map { $0 != input.series.count } ?? false
        }
        return efforts(for: inputs.map(\.key), adding: stale)
    }

    // MARK: Work

    private static func work(_ input: Input) -> [BestEfforts.Distance: Double]? {
        guard let points = try? JSONDecoder().decode([SplitBucketing.DistancePoint].self, from: input.series) else {
            return nil
        }
        let samples = points.map { BestEfforts.Sample(elapsedSeconds: $0.elapsedSeconds, meters: $0.cumulativeMeters) }
        let efforts = BestEfforts.efforts(in: samples)
        return efforts.isEmpty ? nil : efforts
    }

    // MARK: Disk

    /// In Caches: the efforts can always be worked out again, so the system may clear it.
    public static var defaultStoreURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("best-efforts-v1.json")
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([UUID: Entry].self, from: data) else { return }
        // Anything worked out this session wins over what was on disk.
        entries.merge(stored) { current, _ in current }
    }

    private func save() {
        guard let storeURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
