import Foundation
import CoreLocation

// MARK: - RouteSnapper

/// Moves runs onto the streets with Apple Maps walking directions, for the heatmap.
///
/// Each run is cut into pieces by ``RouteSnapping``, and Apple Maps is asked for the
/// walking way between each piece's ends. A piece of street is asked about once: the
/// answer is kept by the cells at its ends (Caches/route-snap-legs-v1.plist), so the
/// home streets every run goes along cost nothing after the first run.
///
/// Apple throttles directions requests, so this asks for one at a time, a little over a
/// second apart, and waits a minute when told to slow down. Years of runs take a while;
/// the heatmap snaps the newest first while it is open and picks up where it left off.
/// Only the ends of each piece are sent, the same as asking Maps for directions.
@MainActor
final class RouteSnapper {
    static let shared = RouteSnapper(storeURL: defaultStoreURL)

    /// Time between two requests: about 45 a minute, under Apple's limit.
    static let spacing: Duration = .milliseconds(1_300)
    /// How long to wait after Apple says to slow down.
    static let throttledPause: Duration = .seconds(60)

    private let storeURL: URL?
    /// Each piece of street asked about: its walking line, or empty when Apple had none
    /// or its line wasn't believable.
    private var legs: [RouteSnapping.Key: [RouteHeatmap.Point]] = [:]
    private var hasLoaded = false
    private var unsaved = 0
    /// Set when the network is down, so the rest of this visit doesn't keep failing.
    private var isOffline = false

    init(storeURL: URL?) {
        self.storeURL = storeURL
    }

    /// The run on the streets, or `nil` if it couldn't be finished (no network, or the
    /// task was cancelled), so it is tried again next time.
    func snap(_ trace: RouteHeatmap.Trace) async -> RouteHeatmap.Trace? {
        loadIfNeeded()
        let pieces = RouteSnapping.legs(of: trace)
        for leg in pieces.joined() where leg.needsRouting && legs[leg.key] == nil {
            guard !Task.isCancelled, !isOffline else { return nil }
            guard let line = await route(leg) else { return nil }
            legs[leg.key] = line
            unsaved += 1
            if unsaved >= 20 { save() }
        }
        let known = legs
        return RouteSnapping.snapped(pieces) { leg in
            guard let line = known[leg.key], !line.isEmpty else { return nil }
            return line
        }
    }

    /// Writes what has been learned so far.
    func save() {
        unsaved = 0
        guard let storeURL, let data = try? PropertyListEncoder().encode(legs) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Apple's walking line for a piece; empty when there is none to have; `nil` when it
    /// couldn't be asked (offline, cancelled), so nothing is remembered.
    private func route(_ leg: RouteSnapping.Leg) async -> [RouteHeatmap.Point]? {
        // The same Apple Maps walking directions Route Genius uses.
        let directions = MapKitWalkingDirections()
        while !Task.isCancelled {
            do {
                let route = try await directions.walkingRoute(from: Self.coordinate(leg.from), to: Self.coordinate(leg.to))
                try? await Task.sleep(for: Self.spacing)
                let line = route.coordinates.map { RouteHeatmap.Point(latitude: $0.latitude, longitude: $0.longitude) }
                return RouteSnapping.accepts(line, for: leg) ? line : []
            } catch RouteGeniusService.RouteError.rateLimited {
                AppLogger.log("Route snapping throttled; waiting", label: "Heatmap", level: .info)
                try? await Task.sleep(for: Self.throttledPause)
            } catch RouteGeniusService.RouteError.noRouteFound, RouteGeniusService.RouteError.decodingError {
                try? await Task.sleep(for: Self.spacing)
                return []
            } catch {
                AppLogger.log("Route snapping stopped: \(error.localizedDescription)", label: "Heatmap", level: .info)
                isOffline = true
                return nil
            }
        }
        return nil
    }

    private static func coordinate(_ point: RouteHeatmap.Point) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    // MARK: Disk

    static var defaultStoreURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("route-snap-legs-v1.plist")
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let stored = try? PropertyListDecoder().decode([RouteSnapping.Key: [RouteHeatmap.Point]].self, from: data)
        else { return }
        legs.merge(stored) { current, _ in current }
    }
}
