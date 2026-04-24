import Foundation
import CoreLocation
import Testing
@testable import RunningApp

struct RouteGeniusServiceTests {

    @Test("generateRouteOptions throws missingAPIKey for empty key")
    func missingAPIKey() async {
        let service = RouteGeniusService()
        let start = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

        do {
            _ = try await service.generateRouteOptions(
                start: start,
                distanceMeters: 5_000,
                routeType: .loop,
                apiKey: ""
            )
            Issue.record("Expected missingAPIKey error")
        } catch let error as RouteGeniusService.RouteError {
            guard case .missingAPIKey = error else {
                Issue.record("Unexpected RouteError: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("generateRouteOptions surfaces unauthorized when ORS returns HTTP 401")
    func unauthorizedStatusCode() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { MockURLProtocol.requestHandler = nil }

        let service = RouteGeniusService(session: Self.makeMockSession())
        let start = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

        do {
            _ = try await service.generateRouteOptions(
                start: start,
                distanceMeters: 5_000,
                routeType: .loop,
                apiKey: "fake-key"
            )
            Issue.record("Expected unauthorized error")
        } catch let error as RouteGeniusService.RouteError {
            guard case .unauthorized = error else {
                Issue.record("Unexpected RouteError: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("generateRouteOptions returns 3 options for successful loop responses")
    func loopSuccess() async throws {
        let body = Self.mockSuccessResponseJSON.data(using: .utf8)!
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let service = RouteGeniusService(session: Self.makeMockSession())
        let start = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

        let options = try await service.generateRouteOptions(
            start: start,
            distanceMeters: 5_000,
            routeType: .loop,
            apiKey: "fake-key"
        )

        #expect(options.count == 3)
        #expect(options[0].label == "Option A")
    }

    private static func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static let mockSuccessResponseJSON = """
    {
      "routes": [
        {
          "summary": { "distance": 5000.0, "duration": 1800.0 },
          "segments": [
            {
              "steps": [
                {
                  "instruction": "Head north",
                  "name": "Main St",
                  "distance": 5000.0,
                  "duration": 1800.0,
                  "type": 0
                }
              ]
            }
          ],
          "geometry": "??"
        }
      ]
    }
    """
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
