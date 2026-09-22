import Testing
import Foundation
import CoreLocation
@testable import Stride

// MARK: - Off-route alerts (A7)
//
// A runner following a saved route is warned, out loud, when they leave it. The tests
// pin the three rules that keep that warning from nagging: nothing is "off" before the
// runner has joined the route, leaving and rejoining use different distances, and one
// stray fix never changes the state.

/// A 1 km route running due north, and helpers to stand a runner some metres east of it.
private enum Fixture {
    static let origin = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1)
    static let metersPerDegreeLatitude = 6_371_000.0 * .pi / 180

    /// Straight north from `origin`, one vertex every 100 m.
    static let route: [Coordinate] = (0...10).map { step in
        Coordinate(CLLocationCoordinate2D(
            latitude: origin.latitude + Double(step) * 100 / metersPerDegreeLatitude,
            longitude: origin.longitude
        ))
    }

    /// A fix `north` metres up the route and `east` metres to the side of it.
    static func fix(north: Double = 500, east: Double) -> Coordinate {
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(origin.latitude * .pi / 180)
        return Coordinate(CLLocationCoordinate2D(
            latitude: origin.latitude + north / metersPerDegreeLatitude,
            longitude: origin.longitude + east / metersPerDegreeLongitude
        ))
    }

    /// A monitor that has already joined the route.
    static func joinedMonitor() -> RouteDeviationMonitor {
        var monitor = RouteDeviationMonitor(route: route)
        for _ in 0..<RouteDeviationMonitor.confirmingFixes {
            _ = monitor.update(with: fix(east: 0))
        }
        return monitor
    }
}

struct RouteDeviationMonitorTests {

    // MARK: Geometry

    @Test("Distance to the route is the perpendicular distance to the nearest segment")
    func perpendicularDistance() throws {
        let onLine = try #require(RouteDeviationMonitor.distanceMeters(from: Fixture.fix(east: 0), toRoute: Fixture.route))
        let beside = try #require(RouteDeviationMonitor.distanceMeters(from: Fixture.fix(north: 550, east: 100), toRoute: Fixture.route))

        #expect(onLine < 0.5)
        #expect(abs(beside - 100) < 1)
    }

    @Test("Past the end of the route, distance is to the end point")
    func distancePastTheEnd() throws {
        let beyond = try #require(RouteDeviationMonitor.distanceMeters(from: Fixture.fix(north: 1_100, east: 0), toRoute: Fixture.route))
        #expect(abs(beyond - 100) < 1)
    }

    @Test("An empty route has no distance; a one-point route measures to that point")
    func degenerateRoutes() throws {
        #expect(RouteDeviationMonitor.distanceMeters(from: Fixture.fix(east: 0), toRoute: []) == nil)
        let single = try #require(RouteDeviationMonitor.distanceMeters(
            from: Fixture.fix(north: 0, east: 40), toRoute: [Fixture.route[0]]
        ))
        #expect(abs(single - 40) < 1)
    }

    // MARK: Joining

    @Test("Far from the route before joining it is approaching, never off route")
    func approachingIsNotOffRoute() {
        var monitor = RouteDeviationMonitor(route: Fixture.route)
        for _ in 0..<10 {
            #expect(monitor.update(with: Fixture.fix(east: 300)) == nil)
        }
        guard case .approaching(let distance) = monitor.status else {
            Issue.record("Expected approaching, got \(monitor.status)")
            return
        }
        #expect(abs(distance - 300) < 1)
    }

    @Test("Joining the route takes several close fixes and is not announced")
    func joiningIsSilent() {
        var monitor = RouteDeviationMonitor(route: Fixture.route)
        for _ in 0..<(RouteDeviationMonitor.confirmingFixes - 1) {
            #expect(monitor.update(with: Fixture.fix(east: 5)) == nil)
        }
        #expect(monitor.status != .onRoute)
        #expect(monitor.update(with: Fixture.fix(east: 5)) == nil)
        #expect(monitor.status == .onRoute)
    }

    // MARK: Leaving and rejoining

    @Test("Leaving is announced on the confirming fix, with the distance")
    func leavingIsAnnounced() {
        var monitor = Fixture.joinedMonitor()
        #expect(monitor.update(with: Fixture.fix(east: 80)) == nil)
        #expect(monitor.update(with: Fixture.fix(east: 80)) == nil)
        let event = monitor.update(with: Fixture.fix(east: 80))

        guard case .leftRoute(let distance) = event else {
            Issue.record("Expected leftRoute, got \(String(describing: event))")
            return
        }
        #expect(abs(distance - 80) < 1)
        #expect(monitor.status == .offRoute(distanceMeters: distance))
    }

    @Test("One close fix between far ones restarts the count")
    func strayFixDoesNotConfirm() {
        var monitor = Fixture.joinedMonitor()
        _ = monitor.update(with: Fixture.fix(east: 80))
        _ = monitor.update(with: Fixture.fix(east: 80))
        _ = monitor.update(with: Fixture.fix(east: 10))
        #expect(monitor.update(with: Fixture.fix(east: 80)) == nil)
        #expect(monitor.update(with: Fixture.fix(east: 80)) == nil)
        #expect(monitor.status == .onRoute)
    }

    @Test("Between the two thresholds the state holds either way")
    func hysteresis() {
        // On route, drifting to 40 m: not far enough to leave.
        var onRoute = Fixture.joinedMonitor()
        for _ in 0..<5 {
            #expect(onRoute.update(with: Fixture.fix(east: 40)) == nil)
        }
        #expect(onRoute.status == .onRoute)

        // Off route, coming back to 40 m: not close enough to rejoin.
        var offRoute = Fixture.joinedMonitor()
        for _ in 0..<RouteDeviationMonitor.confirmingFixes {
            _ = offRoute.update(with: Fixture.fix(east: 80))
        }
        for _ in 0..<5 {
            #expect(offRoute.update(with: Fixture.fix(east: 40)) == nil)
        }
        #expect(offRoute.isOff)
    }

    @Test("Rejoining is announced once, on the confirming fix")
    func rejoiningIsAnnounced() {
        var monitor = Fixture.joinedMonitor()
        for _ in 0..<RouteDeviationMonitor.confirmingFixes {
            _ = monitor.update(with: Fixture.fix(east: 80))
        }
        #expect(monitor.update(with: Fixture.fix(east: 10)) == nil)
        #expect(monitor.update(with: Fixture.fix(east: 10)) == nil)
        #expect(monitor.update(with: Fixture.fix(east: 10)) == .rejoinedRoute)
        #expect(monitor.update(with: Fixture.fix(east: 10)) == nil)
        #expect(monitor.status == .onRoute)
    }
}

private extension RouteDeviationMonitor {
    var isOff: Bool {
        if case .offRoute = status { return true }
        return false
    }
}

// MARK: - RunRouteGuide

@MainActor
struct RunRouteGuideTests {

    /// Collects what the guide would have spoken.
    private final class Spoken {
        var phrases: [String] = []
    }

    @Test("Leaving and rejoining a followed route are spoken")
    func speaksTransitions() {
        let spoken = Spoken()
        let guide = RunRouteGuide { spoken.phrases.append($0) }
        guide.follow(name: "River loop", coordinates: Fixture.route, unit: .metric)

        for _ in 0..<3 { guide.handle(fix: Fixture.fix(east: 0)) }
        for _ in 0..<3 { guide.handle(fix: Fixture.fix(east: 80)) }
        #expect(guide.isOffRoute)
        for _ in 0..<3 { guide.handle(fix: Fixture.fix(east: 0)) }

        #expect(spoken.phrases == [
            "Off route. The route is about 80 metres away.",
            "Back on route."
        ])
        #expect(!guide.isOffRoute)
    }

    @Test("Fixes are ignored when no route is followed, and stop clears the route")
    func stopClears() {
        let spoken = Spoken()
        let guide = RunRouteGuide { spoken.phrases.append($0) }
        guide.handle(fix: Fixture.fix(east: 80))
        #expect(guide.status == nil)

        guide.follow(name: "River loop", coordinates: Fixture.route, unit: .metric)
        guide.handle(fix: Fixture.fix(east: 0))
        #expect(guide.status != nil)

        guide.stop()
        #expect(guide.route == nil)
        #expect(guide.status == nil)
        #expect(spoken.phrases.isEmpty)
    }

    @Test("A route with fewer than two points is not followed")
    func degenerateRouteIgnored() {
        let guide = RunRouteGuide { _ in }
        guide.follow(name: "Dot", coordinates: [Fixture.route[0]], unit: .metric)
        #expect(guide.route == nil)
    }

    @Test("Spoken distances are rounded coarsely in the runner's unit")
    func spokenDistances() {
        #expect(RunRouteGuide.spokenDistance(57, unit: .metric) == "60 metres")
        #expect(RunRouteGuide.spokenDistance(3, unit: .metric) == "10 metres")
        #expect(RunRouteGuide.spokenDistance(1_540, unit: .metric) == "1.5 kilometres")
        #expect(RunRouteGuide.spokenDistance(60, unit: .imperial) == "200 feet")
        #expect(RunRouteGuide.spokenDistance(800, unit: .imperial) == "0.5 miles")
    }
}
