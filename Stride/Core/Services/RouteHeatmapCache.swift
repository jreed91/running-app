import Foundation

// MARK: - RouteHeatmapCache

/// Every run's route on the heatmap grid, worked out once and kept: for the session, and
/// on disk between launches.
///
/// A route blob is the heaviest thing a run stores, so the heatmap reads one only for a
/// run the cache hasn't traced yet: the first time, every run with a route; after that,
/// only new ones. Built like ``BestEffortsCache``: ask which runs are ``missing`` by id
/// and date, read the routes of only those, then ask for the map.
///
/// An actor, so tracing and building run off the main actor.
actor RouteHeatmapCache {
    static let shared = RouteHeatmapCache(storeURL: defaultStoreURL)

    /// A run as the cache knows it without its route.
    struct Key: Sendable, Hashable {
        let id: UUID
        let date: Date
    }

    /// A run with its route blob, read from the model on the main actor.
    struct Input: Sendable, Equatable {
        let id: UUID
        let date: Date
        let route: Data

        var key: Key { Key(id: id, date: date) }
    }

    private struct Entry: Codable {
        let date: Date
        /// `nil` for a run with no route (indoor, or recorded without location), so it
        /// isn't read again.
        let trace: RouteHeatmap.Trace?
    }

    private let storeURL: URL?
    private var entries: [UUID: Entry] = [:]
    private var hasLoaded = false
    private var isDirty = false

    /// The last map built and the runs it was built from, so asking again for the same
    /// runs (a tab switch, the card reappearing) costs nothing.
    private var lastBuilt: (keys: [Key], heatmap: RouteHeatmap.Heatmap)?

    /// How many routes have been traced so far. For tests.
    private(set) var traced = 0

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL
    }

    /// The runs among `keys` not traced yet: new runs, and runs whose date changed.
    func missing(_ keys: [Key]) -> [UUID] {
        loadIfNeeded()
        return keys.compactMap { key in entries[key.id]?.date == key.date ? nil : key.id }
    }

    /// Traces the routes handed over. Call it as many times as it takes to hand over
    /// every route ``missing`` named, a few at a time, so no more than a handful of route
    /// blobs are in memory at once.
    func add(_ inputs: [Input]) {
        loadIfNeeded()
        guard !inputs.isEmpty else { return }
        for input in inputs {
            entries[input.id] = Entry(date: input.date, trace: RouteHeatmap.trace(routeData: input.route))
            traced += 1
        }
        isDirty = true
        lastBuilt = nil
    }

    /// Drops every run not in `ids`, so a deleted run leaves the map, then writes the
    /// cache to disk if anything changed.
    func keep(only ids: Set<UUID>) {
        loadIfNeeded()
        let before = entries.count
        entries = entries.filter { ids.contains($0.key) }
        if entries.count != before {
            isDirty = true
            lastBuilt = nil
        }
        if isDirty { save() }
    }

    /// The map of the runs in `keys`. Runs not traced yet are left out.
    func heatmap(for keys: [Key]) -> RouteHeatmap.Heatmap {
        loadIfNeeded()
        if let lastBuilt, lastBuilt.keys == keys { return lastBuilt.heatmap }
        let traces = keys.compactMap { key -> RouteHeatmap.Trace? in
            guard let entry = entries[key.id], entry.date == key.date else { return nil }
            return entry.trace
        }
        let heatmap = RouteHeatmap.build(traces)
        lastBuilt = (keys, heatmap)
        return heatmap
    }

    /// The runs among `keys` whose route went within about `radiusMeters` of `point`, in
    /// the order given.
    func runs(near point: RouteHeatmap.Point, radiusMeters: Double, among keys: [Key]) -> [UUID] {
        loadIfNeeded()
        let area = RouteHeatmap.cells(around: point, radiusMeters: radiusMeters)
        return keys.compactMap { key in
            guard let entry = entries[key.id], entry.date == key.date,
                  let trace = entry.trace, trace.passes(through: area) else { return nil }
            return key.id
        }
    }

    // MARK: Disk

    /// In Caches: traces can always be worked out again, so the system may clear it.
    static var defaultStoreURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("route-heatmap-v1.plist")
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let stored = try? PropertyListDecoder().decode([UUID: Entry].self, from: data) else { return }
        // Anything traced this session wins over what was on disk.
        entries.merge(stored) { current, _ in current }
    }

    private func save() {
        isDirty = false
        let encoder = PropertyListEncoder()
        // Binary, so each packed trace is stored as raw bytes rather than base64 text.
        encoder.outputFormat = .binary
        guard let storeURL, let data = try? encoder.encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
