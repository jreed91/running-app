import Foundation

/// Everything about talking to Strava that can be decided without a network: the OAuth
/// URLs and callback, the token, upload and activity requests, and how Strava's replies
/// are read.
///
/// Pure request building and response parsing, so all of it can be asserted on directly;
/// `StravaService` owns the Keychain, the `URLSession` and the order the calls go in. The
/// same split `GPXExport` keeps with `RunSummaryView`.
///
/// Endpoints and parameter names follow Strava's v3 API reference
/// (developers.strava.com/docs/reference, /docs/authentication, /docs/uploads).
enum StravaAPI {

    // MARK: - Endpoints

    /// Strava's mobile-optimised consent page. Shown inside `ASWebAuthenticationSession`,
    /// so it works whether or not the Strava app is installed.
    static let authorizeURL = endpoint("https://www.strava.com/oauth/mobile/authorize")
    static let tokenURL = endpoint("https://www.strava.com/oauth/token")
    static let deauthorizeURL = endpoint("https://www.strava.com/oauth/deauthorize")
    static let apiBaseURL = endpoint("https://www.strava.com/api/v3")

    /// The app's existing `stride://` scheme. `ASWebAuthenticationSession` intercepts the
    /// redirect itself, so the callback never reaches `StrideApp.onOpenURL`.
    static let callbackScheme = "stride"
    /// Strava checks the redirect's host against the app's *Authorization Callback Domain*.
    /// `localhost` is on Strava's always-allowed list, and it is also what the app's
    /// settings page on strava.com must say.
    static let redirectURI = "stride://localhost/strava"
    /// `activity:write` is the only scope uploading needs. Strava shows each scope as a
    /// checkbox the athlete can untick, so the callback is checked for it.
    static let requiredScope = "activity:write"

    // MARK: - Credentials

    /// The app's Strava API client, read from the build — never from the repository.
    ///
    /// Both values come from `STRAVA_CLIENT_ID` / `STRAVA_CLIENT_SECRET` build settings
    /// (a gitignored `ci_scripts/Strava.xcconfig` locally, Xcode Cloud secrets in CI) via
    /// Info.plist. A build without them has no Strava feature rather than a broken one.
    struct Credentials: Equatable, Sendable {
        let clientID: String
        let clientSecret: String

        static let clientIDKey = "StravaClientID"
        static let clientSecretKey = "StravaClientSecret"

        /// `nil` when either value is missing, empty, or an unexpanded `$(…)` build
        /// setting — the three ways an unconfigured build shows up in Info.plist.
        static func from(infoDictionary info: [String: Any]?) -> Credentials? {
            func value(_ key: String) -> String? {
                guard let raw = info?[key] as? String else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
                return trimmed
            }
            guard let id = value(clientIDKey), let secret = value(clientSecretKey) else { return nil }
            return Credentials(clientID: id, clientSecret: secret)
        }
    }

    // MARK: - Authorization

    /// The consent page to open. `state` is echoed back on the redirect and checked, so a
    /// stray `stride://localhost/strava` link cannot complete a connection nobody started.
    static func authorizationURL(clientID: String, state: String) -> URL {
        var components = URLComponents()
        components.scheme = authorizeURL.scheme
        components.host = authorizeURL.host()
        components.path = authorizeURL.path()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: requiredScope),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url ?? authorizeURL
    }

    enum CallbackResult: Equatable {
        case code(String)
        /// The athlete pressed Cancel on Strava's page.
        case denied
        /// They connected but unticked "Upload your activities", so nothing could be sent.
        case missingScope
        /// Wrong `state`, or a redirect with neither a code nor an error.
        case invalid
    }

    static func parseCallback(_ url: URL, expectedState: String) -> CallbackResult {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard item("state") == expectedState else { return .invalid }
        if item("error") != nil { return .denied }
        guard let code = item("code"), !code.isEmpty else { return .invalid }
        let scopes = (item("scope") ?? "").split(separator: ",").map(String.init)
        guard scopes.contains(requiredScope) else { return .missingScope }
        return .code(code)
    }

    static func tokenExchangeRequest(code: String, credentials: Credentials) -> URLRequest {
        formRequest(url: tokenURL, method: "POST", fields: [
            ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret),
            ("code", code),
            ("grant_type", "authorization_code")
        ])
    }

    /// Access tokens last six hours. Strava may hand back a *new* refresh token here, and
    /// the old one stops working once the new one has been used, so the caller must store
    /// whatever comes back.
    static func refreshRequest(refreshToken: String, credentials: Credentials) -> URLRequest {
        formRequest(url: tokenURL, method: "POST", fields: [
            ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token")
        ])
    }

    /// Revokes Stride's access on Strava's side, so Disconnect removes the app from the
    /// athlete's *My Apps* list rather than only forgetting the token here.
    static func deauthorizeRequest(accessToken: String) -> URLRequest {
        formRequest(url: deauthorizeURL, method: "POST", fields: [("access_token", accessToken)])
    }

    // MARK: - Activities

    /// A GPX upload. Strava processes it asynchronously and answers with an upload id to
    /// poll, not an activity.
    static func uploadRequest(
        gpx: Data,
        fileName: String,
        draft: StravaActivityDraft,
        accessToken: String,
        boundary: String = "Stride-\(UUID().uuidString)"
    ) -> URLRequest {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("uploads"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            fields: [
                ("data_type", "gpx"),
                ("name", draft.name),
                ("description", draft.description),
                ("external_id", draft.externalID)
            ],
            file: (field: "file", fileName: fileName, contentType: "application/gpx+xml", data: gpx),
            boundary: boundary
        )
        return request
    }

    static func uploadStatusRequest(uploadID: Int64, accessToken: String) -> URLRequest {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("uploads/\(uploadID)"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// A manual activity, for a run with no route — a treadmill run has no GPS trace to
    /// put in a file, but its distance and time are still worth logging.
    static func createActivityRequest(draft: StravaActivityDraft, accessToken: String) -> URLRequest {
        var request = formRequest(url: apiBaseURL.appendingPathComponent("activities"), method: "POST", fields: [
            ("name", draft.name),
            ("sport_type", "Run"),
            ("start_date_local", localTimestamp(draft.startDate, timeZone: draft.timeZone)),
            ("elapsed_time", String(draft.elapsedSeconds)),
            ("distance", String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), draft.distanceMeters)),
            ("description", draft.description),
            ("trainer", draft.isIndoor ? "1" : "0")
        ])
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func activityURL(id: Int64) -> URL {
        endpoint("https://www.strava.com/activities/\(id)")
    }

    /// A URL from a string known to be valid. Every caller passes a fixed https address
    /// with at most a number interpolated into its path.
    private static func endpoint(_ string: String) -> URL {
        guard let url = URL(string: string) else { preconditionFailure("Invalid Strava URL: \(string)") }
        return url
    }

    // MARK: - Responses

    struct TokenResponse: Decodable, Equatable {
        let accessToken: String
        let refreshToken: String
        /// Seconds since 1970.
        let expiresAt: TimeInterval
        /// Present on the first exchange, absent on a refresh.
        let athlete: Athlete?
    }

    struct Athlete: Codable, Equatable {
        let id: Int64
        let firstname: String?
        let lastname: String?

        var displayName: String? {
            let parts = [firstname, lastname]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    struct UploadResponse: Decodable, Equatable {
        let id: Int64
        let error: String?
        let status: String?
        let activityId: Int64?
    }

    struct ActivityResponse: Decodable, Equatable {
        let id: Int64
    }

    /// The body of a non-2xx reply, e.g. `{"message":"Authorization Error", …}`.
    struct Fault: Decodable {
        let message: String?
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    enum UploadOutcome: Equatable {
        case processing
        case ready(activityID: Int64)
        /// Strava already has this run — uploaded before, or synced from Apple Health or a
        /// watch. Treated as done: the run *is* on Strava. The id is there when Strava's
        /// message names the existing activity.
        case duplicate(activityID: Int64?)
        case failed(String)
    }

    static func outcome(of upload: UploadResponse) -> UploadOutcome {
        if let error = upload.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            if error.localizedCaseInsensitiveContains("duplicate") {
                return .duplicate(activityID: duplicateActivityID(in: error))
            }
            return .failed(error)
        }
        if let activityID = upload.activityId { return .ready(activityID: activityID) }
        return .processing
    }

    /// Strava words a duplicate as e.g. `… duplicate of <a href='/activities/123'>…</a>`.
    /// The first run of digits after "duplicate" is the existing activity's id.
    static func duplicateActivityID(in message: String) -> Int64? {
        guard let range = message.range(of: "duplicate", options: .caseInsensitive) else { return nil }
        let digitRuns = message[range.upperBound...]
            .split { !$0.isASCII || !$0.isNumber }
        guard let id = digitRuns.first(where: { $0.count >= 3 }) else { return nil }
        return Int64(id)
    }

    // MARK: - Encoding

    /// `multipart/form-data`, as the upload endpoint requires for the file.
    static func multipartBody(
        fields: [(String, String)],
        file: (field: String, fileName: String, contentType: String, data: Data),
        boundary: String
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.fileName)\"\r\n")
        append("Content-Type: \(file.contentType)\r\n\r\n")
        body.append(file.data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    static func formRequest(url: URL, method: String, fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(fields).utf8)
        return request
    }

    /// Percent-encodes strictly: `URLComponents` leaves `+` and `&` alone in values, and a
    /// form body reads a bare `+` as a space.
    static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(name)=\(encoded)"
        }
        .joined(separator: "&")
    }

    /// Strava reads `start_date_local` as the wall-clock time where the run happened, so it
    /// is written without an offset.
    static func localTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// What Stride tells Strava about one run: the activity's title, description and the id
/// that ties it back to the run.
struct StravaActivityDraft: Equatable, Sendable {
    let name: String
    let description: String
    /// `stride-<run id>`. Strava echoes it back on the upload, and it keeps two uploads of
    /// the same run recognisably the same one.
    let externalID: String
    let startDate: Date
    let timeZone: TimeZone
    let elapsedSeconds: Int
    let distanceMeters: Double
    let isIndoor: Bool

    static func make(for workout: RunWorkout, timeZone: TimeZone = .current) -> StravaActivityDraft {
        StravaActivityDraft(
            name: title(for: workout),
            description: String(
                localized: "Recorded with Stride",
                comment: "Description on a run uploaded to Strava"
            ),
            externalID: "stride-\(workout.id.uuidString.lowercased())",
            startDate: workout.date,
            timeZone: timeZone,
            elapsedSeconds: Int(workout.durationSeconds.rounded()),
            distanceMeters: workout.distanceMeters,
            isIndoor: workout.workoutLocation == .indoor
        )
    }

    /// "Tempo Run", "Long Run", or the race's own name. Written for the runner's Strava
    /// feed, so unlike a GPX track name it is localised.
    private static func title(for workout: RunWorkout) -> String {
        let type = workout.scheduledWorkout?.workoutType ?? workout.workoutType
        switch type {
        case .race:
            let race = workout.scheduledWorkout?.week?.plan?.raceName ?? ""
            let trimmed = race.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return type.localizedName
        case .longRun:
            return type.localizedName
        default:
            return String(
                localized: "\(type.localizedName) Run",
                comment: "Title of a run uploaded to Strava, e.g. Tempo Run"
            )
        }
    }
}
