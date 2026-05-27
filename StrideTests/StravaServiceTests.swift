import Testing
import Foundation
import CoreLocation
@testable import Stride

@Suite(.serialized)
struct StravaServiceTests {

    // MARK: - Token exchange

    @Test("Decodes token response from a successful exchange")
    func exchangeCodeDecodesTokens() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.absoluteString == "https://www.strava.com/oauth/token")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.tokenResponseData)
        }

        let service = StravaService(session: Self.mockSession)
        let tokens = try await service.exchangeCode("abc", clientID: "id", clientSecret: "secret")

        #expect(tokens.accessToken == "access-123")
        #expect(tokens.refreshToken == "refresh-456")
        #expect(tokens.expiresAt == 1_900_000_000)
        #expect(tokens.athleteName == "Jane Doe")
    }

    @Test("Maps 401 upload responses to unauthorized")
    func uploadUnauthorized() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let service = StravaService(session: Self.mockSession)
        do {
            _ = try await service.uploadGPX(
                Data("<gpx/>".utf8),
                name: "Run",
                description: nil,
                externalID: "ext-1",
                accessToken: "token"
            )
            Issue.record("Expected unauthorized error")
        } catch StravaService.StravaError.unauthorized {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Parses accepted upload response")
    func uploadAccepted() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let body = #"{"id": 555, "external_id": "ext-1", "error": null, "status": "processing", "activity_id": null}"#
            return (response, Data(body.utf8))
        }

        let service = StravaService(session: Self.mockSession)
        let upload = try await service.uploadGPX(
            Data("<gpx/>".utf8),
            name: "Run",
            description: "notes",
            externalID: "ext-1",
            accessToken: "token"
        )

        #expect(upload.id == 555)
        #expect(upload.activityID == nil)
        #expect(upload.error == nil)
    }

    @Test("Builds an authorization URL with the write scope")
    func authorizationURLContainsScope() {
        let service = StravaService(session: Self.mockSession)
        let url = service.authorizationURL(clientID: "id", redirectURI: "stride://strava-auth")
        let string = url?.absoluteString ?? ""
        #expect(string.contains("client_id=id"))
        #expect(string.contains("activity:write"))
        #expect(string.contains("response_type=code"))
    }

    private static let mockSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }()

    private static let tokenResponseData = Data("""
    {
      "access_token": "access-123",
      "refresh_token": "refresh-456",
      "expires_at": 1900000000,
      "athlete": { "firstname": "Jane", "lastname": "Doe" }
    }
    """.utf8)
}

// MARK: - GPX builder

@Suite struct StravaGPXBuilderTests {

    @Test("Returns nil when there are fewer than two coordinates")
    func noRouteReturnsNil() {
        let workout = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_500)
        #expect(StravaGPXBuilder.makeGPX(for: workout) == nil)

        workout.routeCoordinates = [Coordinate(CLLocationCoordinate2D(latitude: 1, longitude: 2))]
        #expect(StravaGPXBuilder.makeGPX(for: workout) == nil)
    }

    @Test("Produces GPX with a track point per coordinate and timestamps")
    func buildsTrackPoints() throws {
        let workout = RunWorkout(date: Date(timeIntervalSince1970: 1_700_000_000),
                                 distanceMeters: 3_000, durationSeconds: 900)
        workout.routeCoordinates = [
            Coordinate(CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)),
            Coordinate(CLLocationCoordinate2D(latitude: 37.1, longitude: -122.1)),
            Coordinate(CLLocationCoordinate2D(latitude: 37.2, longitude: -122.2))
        ]

        let data = try #require(StravaGPXBuilder.makeGPX(for: workout))
        let xml = try #require(String(data: data, encoding: .utf8))

        #expect(xml.components(separatedBy: "<trkpt").count - 1 == 3)
        #expect(xml.contains("<time>"))
        #expect(xml.contains("lat=\"37.0\""))
        #expect(xml.contains("<type>running</type>"))
    }
}

// MARK: - Tokens & duplicate parsing

@Suite struct StravaTokenLogicTests {

    @Test("Tokens expiring within five minutes count as expired")
    func tokenExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = StravaTokens(accessToken: "a", refreshToken: "r",
                                 expiresAt: now.addingTimeInterval(3_600), athleteName: nil)
        let soon = StravaTokens(accessToken: "a", refreshToken: "r",
                                expiresAt: now.addingTimeInterval(60), athleteName: nil)
        let past = StravaTokens(accessToken: "a", refreshToken: "r",
                                expiresAt: now.addingTimeInterval(-10), athleteName: nil)

        #expect(fresh.isExpired(now: now) == false)
        #expect(soon.isExpired(now: now) == true)
        #expect(past.isExpired(now: now) == true)
    }

    @Test("Recovers activity id from a duplicate-upload error")
    func parsesDuplicateActivityID() {
        #expect(StravaSyncService.parseDuplicateActivityID(from: "duplicate of activity 12345") == 12345)
        #expect(StravaSyncService.parseDuplicateActivityID(from: "There was an error processing your activity.") == nil)
        #expect(StravaSyncService.parseDuplicateActivityID(from: "") == nil)
    }
}

// MARK: - Mock URL protocol

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

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
