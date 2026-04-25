import Testing
import Foundation
import CoreLocation
@testable import RunningApp

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
