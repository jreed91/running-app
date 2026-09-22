import Testing
import Foundation
import CoreLocation
@testable import Stride

@Suite(.serialized)
struct RouteGeniusServiceTests {

    @Test("Returns decoded routes for successful responses")
    func generateRouteOptionsSuccess() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "test-key")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Self.sampleResponseData)
        }

        let service = RouteGeniusService(session: Self.mockSession)
        let routes = try await service.generateRouteOptions(
            start: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            distanceMeters: 5_000,
            routeType: .loop,
            apiKey: "test-key"
        )

        #expect(routes.count == 3)
        #expect(routes.first?.distanceMeters == 1_000)
        #expect(!(routes.first?.coordinates.isEmpty ?? true))
    }

    @Test("Maps 401 responses to unauthorized error")
    func generateRouteOptionsUnauthorized() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let service = RouteGeniusService(session: Self.mockSession)

        do {
            _ = try await service.generateRouteOptions(
                start: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                distanceMeters: 5_000,
                routeType: .loop,
                apiKey: "bad-key"
            )
            Issue.record("Expected unauthorized error")
        } catch RouteGeniusService.RouteError.unauthorized {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Maps 429 responses to rate-limited error")
    func generateRouteOptionsRateLimited() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let service = RouteGeniusService(session: Self.mockSession)

        do {
            _ = try await service.generateRouteOptions(
                start: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                distanceMeters: 5_000,
                routeType: .loop,
                apiKey: "test-key"
            )
            Issue.record("Expected rate-limited error")
        } catch RouteGeniusService.RouteError.rateLimited {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: Keyless (Apple Maps) generation

    private static let start = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

    /// Any URL request in a keyless test is a bug: the keyless path must not reach ORS.
    private static func failOnAnyRequest() {
        MockURLProtocol.requestHandler = { request in
            Issue.record("Unexpected ORS request to \(request.url?.absoluteString ?? "nil")")
            throw URLError(.badServerResponse)
        }
    }

    @Test("No key: loops come from walking directions and close back at the start")
    func keylessLoopUsesWalkingDirections() async throws {
        Self.failOnAnyRequest()
        let directions = FakeWalkingDirections(detourFactor: RouteGeniusService.assumedDetourFactor)
        let service = RouteGeniusService(session: Self.mockSession, directions: directions)

        let routes = try await service.generateRouteOptions(
            start: Self.start, distanceMeters: 5_000, routeType: .loop, apiKey: ""
        )

        #expect(routes.map(\.label) == ["Option A", "Option B", "Option C"])
        // Start → waypoint → waypoint → start, once per option: the first guess is
        // already within tolerance at the assumed detour factor, so no refinement.
        #expect(directions.callCount == 9)
        for route in routes {
            #expect(route.coordinates.first == Coordinate(Self.start))
            #expect(route.coordinates.last == Coordinate(Self.start))
            #expect(RouteGeniusService.isLegWithinTolerance(routedLegMeters: route.distanceMeters, targetLegMeters: 5_000))
        }
        // Different first-waypoint bearings give different shapes.
        #expect(Set(routes.map { $0.coordinates[1] }).count == 3)
    }

    @Test("No key: a loop that routes long is rescaled once toward the target")
    func keylessLoopRefinesDistance() async throws {
        Self.failOnAnyRequest()
        // Streets twice as winding as assumed: the first loop comes back ~60 % long.
        let directions = FakeWalkingDirections(detourFactor: 2.0)
        let service = RouteGeniusService(session: Self.mockSession, directions: directions)

        let routes = try await service.generateRouteOptions(
            start: Self.start, distanceMeters: 5_000, routeType: .loop, apiKey: ""
        )

        #expect(routes.count == 3)
        #expect(directions.callCount == 18)
        for route in routes {
            #expect(RouteGeniusService.isLegWithinTolerance(routedLegMeters: route.distanceMeters, targetLegMeters: 5_000))
        }
    }

    @Test("No key: out-and-back runs one walking leg there and back")
    func keylessOutAndBack() async throws {
        Self.failOnAnyRequest()
        let directions = FakeWalkingDirections(detourFactor: RouteGeniusService.assumedDetourFactor)
        let service = RouteGeniusService(session: Self.mockSession, directions: directions)

        let routes = try await service.generateRouteOptions(
            start: Self.start, distanceMeters: 6_000, routeType: .outAndBack, apiKey: ""
        )

        #expect(routes.count == 3)
        #expect(directions.callCount == 3)
        for route in routes {
            #expect(route.coordinates.first == Coordinate(Self.start))
            #expect(route.coordinates.last == Coordinate(Self.start))
            #expect(abs(route.distanceMeters - 6_000) / 6_000 <= RouteGeniusService.outAndBackTolerance)
        }
    }

    @Test("No key: a throttled Apple Maps request surfaces as rate-limited")
    func keylessErrorsSurface() async {
        Self.failOnAnyRequest()
        let directions = FakeWalkingDirections(detourFactor: 1.25, error: .rateLimited)
        let service = RouteGeniusService(session: Self.mockSession, directions: directions)

        do {
            _ = try await service.generateRouteOptions(
                start: Self.start, distanceMeters: 5_000, routeType: .loop, apiKey: ""
            )
            Issue.record("Expected rate-limited error")
        } catch RouteGeniusService.RouteError.rateLimited {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("With a key, walking directions are never consulted")
    func keyedPathSkipsWalkingDirections() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.sampleResponseData)
        }
        let directions = FakeWalkingDirections(detourFactor: 1.25)
        let service = RouteGeniusService(session: Self.mockSession, directions: directions)

        _ = try await service.generateRouteOptions(
            start: Self.start, distanceMeters: 5_000, routeType: .outAndBack, apiKey: "test-key"
        )

        #expect(directions.callCount == 0)
    }

    @Test("Joined legs share one coordinate at each join and sum their totals")
    func joinedLegs() {
        let a = Coordinate(CLLocationCoordinate2D(latitude: 0, longitude: 0))
        let b = Coordinate(CLLocationCoordinate2D(latitude: 0, longitude: 1))
        let c = Coordinate(CLLocationCoordinate2D(latitude: 1, longitude: 1))
        let step = RouteStep(instruction: "Go", name: "", distanceMeters: 1, durationSeconds: 1)
        let legs = [
            GeneratedRoute(coordinates: [a, b], steps: [step], distanceMeters: 100, durationSeconds: 60, label: ""),
            GeneratedRoute(coordinates: [b, c], steps: [step, step], distanceMeters: 50, durationSeconds: 30, label: "")
        ]

        let joined = RouteGeniusService.joined(legs)

        #expect(joined.coordinates == [a, b, c])
        #expect(joined.steps.count == 3)
        #expect(joined.distanceMeters == 150)
        #expect(joined.durationSeconds == 90)
    }

    @Test("Loop waypoints sit at the requested offset, 60 degrees apart")
    func loopWaypointGeometry() {
        let waypoints = RouteGeniusService.loopWaypoints(start: Self.start, bearing: 0, offsetMeters: 1_000)
        let origin = CLLocation(latitude: Self.start.latitude, longitude: Self.start.longitude)
        let first = CLLocation(latitude: waypoints[0].latitude, longitude: waypoints[0].longitude)
        let second = CLLocation(latitude: waypoints[1].latitude, longitude: waypoints[1].longitude)

        #expect(abs(origin.distance(from: first) - 1_000) < 5)
        #expect(abs(origin.distance(from: second) - 1_000) < 5)
        // Equilateral: the side between the waypoints matches the offset too.
        #expect(abs(first.distance(from: second) - 1_000) < 5)
    }

    private static let mockSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }()

    private static let sampleResponseData = """
    {
      "routes": [
        {
          "summary": { "distance": 1000.0, "duration": 360.0 },
          "segments": [
            {
              "steps": [
                {
                  "instruction": "Head north",
                  "name": "Main St",
                  "distance": 1000.0,
                  "duration": 360.0,
                  "type": 11
                }
              ]
            }
          ],
          "geometry": "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
        }
      ]
    }
    """.data(using: .utf8)!
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Walking directions that answer instantly with a straight line from `start` to `end`,
/// reporting its length times `detourFactor` as the routed distance.
private final class FakeWalkingDirections: WalkingDirectionsProvider, @unchecked Sendable {
    private let detourFactor: Double
    private let error: RouteGeniusService.RouteError?
    private let lock = NSLock()
    private var calls = 0

    init(detourFactor: Double, error: RouteGeniusService.RouteError? = nil) {
        self.detourFactor = detourFactor
        self.error = error
    }

    var callCount: Int { lock.withLock { calls } }

    func walkingRoute(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) async throws -> GeneratedRoute {
        lock.withLock { calls += 1 }
        if let error { throw error }
        let straight = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        let distance = straight * detourFactor
        return GeneratedRoute(
            coordinates: [Coordinate(start), Coordinate(end)],
            steps: [RouteStep(instruction: "Head on", name: "", distanceMeters: distance, durationSeconds: distance * 0.72)],
            distanceMeters: distance,
            durationSeconds: distance * 0.72,
            label: ""
        )
    }
}
