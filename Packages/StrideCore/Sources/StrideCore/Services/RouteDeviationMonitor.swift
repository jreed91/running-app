import Foundation

// MARK: - RouteDeviationMonitor

/// Decides, fix by fix, whether a runner following a saved route is on it, has left it,
/// or has not reached it yet. Pure — no CoreLocation, no clock — so every threshold is
/// unit-tested.
///
/// Three rules keep it from nagging:
///
/// - **Nothing is "off" until the runner has been on.** A run usually starts at the front
///   door, not on the route's first coordinate; being 300 m from a route you are walking
///   towards is `.approaching`, not a mistake.
/// - **Hysteresis.** Leaving takes more than ``offRouteThresholdMeters``; coming back takes
///   less than ``backOnRouteThresholdMeters``. A runner hovering at one boundary — a wide
///   road, a path beside the drawn line — would otherwise flip on every fix.
/// - **Confirmation.** One stray fix is GPS, not a wrong turn, so a change of state needs
///   several consecutive fixes that agree. The tracker drops fixes closer than 5 m apart,
///   so three fixes are at least ~15 m of actual movement.
struct RouteDeviationMonitor: Sendable {

    enum Status: Equatable, Sendable {
        /// Not yet on the route; the associated value is how far away it is.
        case approaching(distanceMeters: Double)
        case onRoute
        /// Left the route; the associated value is how far away it is now.
        case offRoute(distanceMeters: Double)
    }

    /// The transitions worth telling the runner about.
    enum Event: Equatable, Sendable {
        case leftRoute(distanceMeters: Double)
        case rejoinedRoute
    }

    /// Farther than this from the route counts towards leaving it. Wider than a city
    /// street plus consumer-GPS error, so running on the other pavement is not "off".
    static let offRouteThresholdMeters = 50.0
    /// Closer than this counts towards being on it — joining it the first time, or
    /// coming back after leaving.
    static let backOnRouteThresholdMeters = 30.0
    /// Consecutive agreeing fixes needed before the state changes.
    static let confirmingFixes = 3

    let route: [Coordinate]
    private(set) var status: Status = .approaching(distanceMeters: .infinity)

    private var fixesBeyond = 0
    private var fixesWithin = 0

    init(route: [Coordinate]) {
        self.route = route
    }

    /// Feeds one accepted fix. Returns an event when the fix confirms a change the runner
    /// should hear about; joining the route for the first time is not one.
    mutating func update(with fix: Coordinate) -> Event? {
        guard let distance = Self.distanceMeters(from: fix, toRoute: route) else { return nil }

        if distance > Self.offRouteThresholdMeters {
            fixesBeyond += 1
        } else {
            fixesBeyond = 0
        }
        if distance < Self.backOnRouteThresholdMeters {
            fixesWithin += 1
        } else {
            fixesWithin = 0
        }

        switch status {
        case .approaching:
            if fixesWithin >= Self.confirmingFixes {
                status = .onRoute
            } else {
                status = .approaching(distanceMeters: distance)
            }
            return nil
        case .onRoute:
            guard fixesBeyond >= Self.confirmingFixes else { return nil }
            status = .offRoute(distanceMeters: distance)
            return .leftRoute(distanceMeters: distance)
        case .offRoute:
            if fixesWithin >= Self.confirmingFixes {
                status = .onRoute
                return .rejoinedRoute
            }
            status = .offRoute(distanceMeters: distance)
            return nil
        }
    }

    // MARK: Geometry

    /// Shortest distance in metres from `point` to the polyline through `route`, or `nil`
    /// for an empty route.
    ///
    /// Projects onto a flat plane centred on `point` (equirectangular). Over the few
    /// hundred metres that matter here the error is far below GPS error, and it keeps the
    /// per-fix cost to a few multiplications per route vertex.
    static func distanceMeters(from point: Coordinate, toRoute route: [Coordinate]) -> Double? {
        guard let first = route.first else { return nil }

        let earthRadius = 6_371_000.0
        let metersPerDegreeLatitude = earthRadius * .pi / 180
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(point.latitude * .pi / 180)

        func planar(_ coordinate: Coordinate) -> (x: Double, y: Double) {
            ((coordinate.longitude - point.longitude) * metersPerDegreeLongitude,
             (coordinate.latitude - point.latitude) * metersPerDegreeLatitude)
        }

        var previous = planar(first)
        var best = hypot(previous.x, previous.y)
        for coordinate in route.dropFirst() {
            let current = planar(coordinate)
            best = min(best, distanceFromOrigin(toSegmentFrom: previous, to: current))
            previous = current
        }
        return best
    }

    /// Distance from (0, 0) to the segment `start`–`end`.
    private static func distanceFromOrigin(
        toSegmentFrom start: (x: Double, y: Double),
        to end: (x: Double, y: Double)
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(start.x, start.y) }
        // Where the origin projects onto the line, clamped to the segment.
        let fraction = min(max(-(start.x * dx + start.y * dy) / lengthSquared, 0), 1)
        return hypot(start.x + fraction * dx, start.y + fraction * dy)
    }
}
