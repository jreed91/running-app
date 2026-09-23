import Testing
import Foundation
@testable import Stride

// MARK: - StravaAPI tests (Strava upload)
//
// Everything about the Strava connection that is decided without a network: where the
// credentials come from, the consent URL and its redirect, the requests, and how Strava's
// replies are read.

struct StravaAPITests {

    private let credentials = StravaAPI.Credentials(clientID: "12345", clientSecret: "s3cr3t")

    private func callback(_ query: String) throws -> URL {
        try #require(URL(string: "stride://localhost/strava?\(query)"))
    }

    private func body(_ request: URLRequest) -> String {
        String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    }

    // MARK: Credentials

    @Test("A build without Strava settings has no credentials")
    func unconfiguredBuildHasNoCredentials() {
        #expect(StravaAPI.Credentials.from(infoDictionary: nil) == nil)
        #expect(StravaAPI.Credentials.from(infoDictionary: [:]) == nil)
        #expect(StravaAPI.Credentials.from(infoDictionary: [
            "StravaClientID": "", "StravaClientSecret": ""
        ]) == nil)
        #expect(StravaAPI.Credentials.from(infoDictionary: [
            "StravaClientID": "$(STRAVA_CLIENT_ID)", "StravaClientSecret": "$(STRAVA_CLIENT_SECRET)"
        ]) == nil)
        #expect(StravaAPI.Credentials.from(infoDictionary: ["StravaClientID": "12345"]) == nil)
    }

    @Test("Configured values are read and trimmed")
    func configuredBuildReadsCredentials() {
        let read = StravaAPI.Credentials.from(infoDictionary: [
            "StravaClientID": " 12345 ", "StravaClientSecret": "s3cr3t\n"
        ])
        #expect(read == credentials)
    }

    // MARK: Authorization

    @Test("The consent URL asks for upload permission and carries the state")
    func authorizationURL() throws {
        let url = StravaAPI.authorizationURL(clientID: "12345", state: "abc")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.host == "www.strava.com")
        #expect(components.path == "/oauth/mobile/authorize")
        #expect(items["client_id"] == "12345")
        #expect(items["redirect_uri"] == "stride://localhost/strava")
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "activity:write")
        #expect(items["state"] == "abc")
    }

    @Test("A granted redirect yields its code")
    func callbackWithCode() throws {
        let url = try callback("state=abc&code=xyz&scope=read,activity:write")
        #expect(StravaAPI.parseCallback(url, expectedState: "abc") == .code("xyz"))
    }

    @Test("Cancel on Strava's page is a denial, not an error")
    func callbackDenied() throws {
        let url = try callback("state=abc&error=access_denied")
        #expect(StravaAPI.parseCallback(url, expectedState: "abc") == .denied)
    }

    @Test("Unticking upload permission is caught at connect time")
    func callbackWithoutUploadScope() throws {
        let url = try callback("state=abc&code=xyz&scope=read")
        #expect(StravaAPI.parseCallback(url, expectedState: "abc") == .missingScope)
    }

    @Test("A redirect with the wrong state or no code is rejected")
    func callbackInvalid() throws {
        let wrongState = try callback("state=other&code=xyz&scope=activity:write")
        let noCode = try callback("state=abc&scope=activity:write")
        #expect(StravaAPI.parseCallback(wrongState, expectedState: "abc") == .invalid)
        #expect(StravaAPI.parseCallback(noCode, expectedState: "abc") == .invalid)
    }

    @Test("The token exchange posts the code with the client's credentials")
    func tokenExchangeRequest() {
        let request = StravaAPI.tokenExchangeRequest(code: "xyz", credentials: credentials)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://www.strava.com/oauth/token")
        #expect(body(request) == "client_id=12345&client_secret=s3cr3t&code=xyz&grant_type=authorization_code")
    }

    @Test("A refresh posts the refresh token")
    func refreshRequest() {
        let request = StravaAPI.refreshRequest(refreshToken: "r1", credentials: credentials)
        #expect(body(request).contains("refresh_token=r1"))
        #expect(body(request).contains("grant_type=refresh_token"))
    }

    @Test("Form values are strictly percent-encoded")
    func formEncoding() {
        #expect(StravaAPI.formEncoded([("a", "1+2 & 3=4")]) == "a=1%2B2%20%26%203%3D4")
    }

    @Test("A token reply decodes from Strava's snake_case")
    func tokenResponseDecodes() throws {
        let json = """
        {"token_type":"Bearer","expires_at":1800000000,"expires_in":21600,
         "refresh_token":"r1","access_token":"a1",
         "athlete":{"id":42,"firstname":"Jacob","lastname":"R"}}
        """
        let token = try StravaAPI.decoder.decode(StravaAPI.TokenResponse.self, from: Data(json.utf8))
        #expect(token.accessToken == "a1")
        #expect(token.refreshToken == "r1")
        #expect(token.expiresAt == 1_800_000_000)
        #expect(token.athlete?.displayName == "Jacob R")
    }

    // MARK: Uploads

    @Test("The upload is multipart with the GPX file and the run's details")
    func uploadRequest() {
        let draft = StravaActivityDraft(
            name: "Tempo Run",
            description: "Recorded with Stride",
            externalID: "stride-1",
            startDate: Date(timeIntervalSince1970: 0),
            timeZone: .gmt,
            elapsedSeconds: 1_800,
            distanceMeters: 5_000,
            isIndoor: false
        )
        let request = StravaAPI.uploadRequest(
            gpx: Data("<gpx/>".utf8),
            fileName: "run.gpx",
            draft: draft,
            accessToken: "a1",
            boundary: "B"
        )
        let text = body(request)
        #expect(request.url?.absoluteString == "https://www.strava.com/api/v3/uploads")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B")
        #expect(text.contains("name=\"data_type\"\r\n\r\ngpx\r\n"))
        #expect(text.contains("name=\"external_id\"\r\n\r\nstride-1\r\n"))
        #expect(text.contains("name=\"file\"; filename=\"run.gpx\"\r\n"))
        #expect(text.contains("<gpx/>"))
        #expect(text.hasSuffix("\r\n--B--\r\n"))
    }

    @Test("Upload replies read as processing, ready, failed or duplicate")
    func uploadOutcomes() {
        func reply(error: String? = nil, activity: Int64? = nil) -> StravaAPI.UploadResponse {
            StravaAPI.UploadResponse(id: 1, error: error, status: nil, activityId: activity)
        }
        #expect(StravaAPI.outcome(of: reply()) == .processing)
        #expect(StravaAPI.outcome(of: reply(activity: 99)) == .ready(activityID: 99))
        #expect(StravaAPI.outcome(of: reply(error: "Bad file")) == .failed("Bad file"))
        let duplicate = "run.gpx duplicate of <a href='/activities/1234567' target='_blank'>Run</a>"
        #expect(StravaAPI.outcome(of: reply(error: duplicate)) == .duplicate(activityID: 1_234_567))
        #expect(StravaAPI.outcome(of: reply(error: "Duplicate upload")) == .duplicate(activityID: nil))
    }

    @Test("An upload reply decodes from Strava's snake_case")
    func uploadResponseDecodes() throws {
        let json = """
        {"id":7,"id_str":"7","external_id":"stride-1","error":null,
         "status":"Your activity is ready.","activity_id":99}
        """
        let upload = try StravaAPI.decoder.decode(StravaAPI.UploadResponse.self, from: Data(json.utf8))
        #expect(upload.id == 7)
        #expect(upload.activityId == 99)
        #expect(StravaAPI.outcome(of: upload) == .ready(activityID: 99))
    }

    @Test("A routeless run is created as a manual activity at its local start time")
    func createActivityRequest() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let draft = StravaActivityDraft(
            name: "Easy Run",
            description: "Recorded with Stride",
            externalID: "stride-1",
            // 2027-01-15 12:30:00 UTC = 07:30 in New York
            startDate: Date(timeIntervalSince1970: 1_800_016_200),
            timeZone: zone,
            elapsedSeconds: 1_800,
            distanceMeters: 5_000,
            isIndoor: true
        )
        let text = body(StravaAPI.createActivityRequest(draft: draft, accessToken: "a1"))
        #expect(text.contains("sport_type=Run"))
        #expect(text.contains("start_date_local=2027-01-15T07%3A30%3A00"))
        #expect(text.contains("elapsed_time=1800"))
        #expect(text.contains("distance=5000.0"))
        #expect(text.contains("trainer=1"))
    }

    // MARK: Drafts

    @Test("A run's draft names its type and keeps its id")
    func draftFromRun() {
        let run = RunWorkout(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            distanceMeters: 8_000,
            durationSeconds: 2_400.6,
            workoutType: .tempo,
            workoutLocation: .indoor
        )
        let draft = StravaActivityDraft.make(for: run, timeZone: .gmt)
        #expect(draft.name == "Tempo Run")
        #expect(draft.externalID == "stride-\(run.id.uuidString.lowercased())")
        #expect(draft.elapsedSeconds == 2_401)
        #expect(draft.isIndoor)
    }

    @Test("A long run is not called a Long Run Run")
    func longRunName() {
        let run = RunWorkout(distanceMeters: 20_000, durationSeconds: 7_200, workoutType: .longRun)
        #expect(StravaActivityDraft.make(for: run).name == "Long Run")
    }

    @MainActor
    @Test("Walks never go to Strava")
    func walksAreNotUploaded() {
        let walk = RunWorkout(distanceMeters: 2_000, durationSeconds: 1_500, workoutType: .walk)
        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_500, workoutType: .easy)
        #expect(!StravaService.canUpload(walk))
        #expect(StravaService.canUpload(run))
    }
}
