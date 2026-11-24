import Foundation

// MARK: - RouteStatsCache

/// Every run's heart rate, pace and hills placed on the heatmap grid, worked out once and
/// kept, for the full-screen heatmap's stat layers.
///
/// Built like ``RouteHeatmapCache``: ask which runs are ``missing``, read the blobs of
/// only those (route, distance series and heart-rate samples), then ask for the map. Kept
/// apart from the route cache so the run-count heatmap never waits on, or reads, the
/// heavier blobs a stat layer needs.
actor RouteStatsCache {
    static let shared = RouteStatsCache(storeURL: defaultStoreURL)

    /// A run with the blobs a stat layer needs, read from the model off the main actor.
    struct Input: Sendable, Equatable {
        let id: UUID
        let date: Date
        let route: Data
        let series: Data
        let heartRate: Data
        let durationSeconds: Double
    }

    private struct Entry: Codable {
        let date: Date
        /// `nil` for a run with no route or no stats, so it isn't read again.
        let stats: RouteHeatmap.RunStats?
    }

    private let storeURL: URL?
    private var entries: [UUID: Entry] = [:]
    private var hasLoaded = false
    private var isDirty = false
    private var lastBuilt: (keys: [RouteHeatmapCache.Key], stat: RouteHeatmap.Stat, map: RouteHeatmap.StatMap)?

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL
    }

    /// The runs among `keys` not worked out yet: new runs, and runs whose date changed.
    func missing(_ keys: [RouteHeatmapCache.Key]) -> [UUID] {
        loadIfNeeded()
        return keys.compactMap { key in entries[key.id]?.date == key.date ? nil : key.id }
    }

    /// Works out the stats of the runs handed over, a few at a time like the route cache.
    func add(_ inputs: [Input]) {
        loadIfNeeded()
        guard !inputs.isEmpty else { return }
        for input in inputs {
            entries[input.id] = Entry(date: input.date, stats: Self.stats(of: input))
        }
        isDirty = true
        lastBuilt = nil
    }

    static func stats(of input: Input) -> RouteHeatmap.RunStats? {
        guard !input.route.isEmpty,
              let route = try? JSONDecoder().decode([RouteHeatmap.Point].self, from: input.route) else { return nil }
        let series = input.series.isEmpty
            ? []
            : (try? JSONDecoder().decode([SplitBucketing.DistancePoint].self, from: input.series)) ?? []
        let heartRate = input.heartRate.isEmpty
            ? []
            : (try? JSONDecoder().decode([Double].self, from: input.heartRate)) ?? []
        let stats = RouteHeatmap.stats(
            route: route,
            series: series,
            heartRate: heartRate,
            durationSeconds: input.durationSeconds
        )
        return stats.isEmpty ? nil : stats
    }

    /// Drops every run not in `ids`, then writes the cache to disk if anything changed.
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

    /// The stat across the runs in `keys`. Runs not worked out yet are left out.
    func statMap(for keys: [RouteHeatmapCache.Key], stat: RouteHeatmap.Stat) -> RouteHeatmap.StatMap {
        loadIfNeeded()
        if let lastBuilt, lastBuilt.keys == keys, lastBuilt.stat == stat { return lastBuilt.map }
        let runs = keys.compactMap { key -> RouteHeatmap.RunStats? in
            guard let entry = entries[key.id], entry.date == key.date else { return nil }
            return entry.stats
        }
        let map = RouteHeatmap.statMap(runs, stat: stat)
        lastBuilt = (keys, stat, map)
        return map
    }

    // MARK: Disk

    /// In Caches: the stats can always be worked out again.
    /// v2: traces no longer fill gaps over ``RouteHeatmap/fillMeters`` with a straight line.
    static var defaultStoreURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("route-stats-v2.plist")
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let stored = try? PropertyListDecoder().decode([UUID: Entry].self, from: data) else { return }
        entries.merge(stored) { current, _ in current }
    }

    private func save() {
        isDirty = false
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let storeURL, let data = try? encoder.encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
