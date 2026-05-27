import Foundation

// MARK: - StravaService

/// Talks to the Strava v3 API: OAuth token exchange/refresh and GPX activity uploads.
///
/// **App credentials**: add a `Secrets.plist` to the app bundle with `StravaClientID`
/// and `StravaClientSecret` from your Strava API application
/// (https://www.strava.com/settings/api). Copy `Secrets.plist.example` as a starting
/// point. Without credentials the Strava connect flow is disabled and uploads no-op.
struct StravaService: Sendable {

    // MARK: Errors

    enum StravaError: LocalizedError, Equatable {
        case notConfigured
        case notConnected
        case noGPSData
        case networkError(String)
        case unauthorized
        case rateLimited
        case serverError(statusCode: Int)
        case unexpectedStatusCode(Int)
        case invalidResponse
        case uploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Strava is not configured. Add StravaClientID and StravaClientSecret to Secrets.plist."
            case .notConnected:
                return "Connect your Strava account in Settings first."
            case .noGPSData:
                return "This run has no GPS route, so it can't be uploaded as a GPX activity."
            case .networkError(let message):
                return "Network error: \(message)"
            case .unauthorized:
                return "Strava authorization expired. Reconnect your account in Settings."
            case .rateLimited:
                return "Strava rate limit reached. Please try again later."
            case .serverError:
                return "Strava is temporarily unavailable. Please try again."
            case .unexpectedStatusCode(let code):
                return "Strava returned an unexpected response (\(code))."
            case .invalidResponse:
                return "Strava returned an invalid response."
            case .uploadFailed(let message):
                return "Strava could not process the upload: \(message)"
            }
        }
    }

    // MARK: Configuration

    private let oauthBase = "https://www.strava.com/oauth"
    private let apiBase = "https://www.strava.com/api/v3"
    private let session: any StrideURLSessionProtocol

    init(session: any StrideURLSessionProtocol = PulseIntegrationService.makeURLSession()) {
        self.session = session
    }

    // MARK: OAuth

    /// Builds the mobile authorization URL the user is sent to in order to grant access.
    func authorizationURL(clientID: String, redirectURI: String) -> URL? {
        var components = URLComponents(string: "\(oauthBase)/mobile/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: "activity:write,read")
        ]
        return components?.url
    }

    func exchangeCode(
        _ code: String,
        clientID: String,
        clientSecret: String
    ) async throws -> StravaTokenResponse {
        try await postToken(parameters: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "grant_type": "authorization_code"
        ])
    }

    func refreshTokens(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) async throws -> StravaTokenResponse {
        try await postToken(parameters: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
    }

    private func postToken(parameters: [String: String]) async throws -> StravaTokenResponse {
        guard let url = URL(string: "\(oauthBase)/token") else { throw StravaError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(parameters).data(using: .utf8)

        let (data, response) = try await perform(request)
        try Self.validate(response, data: data)
        do {
            return try JSONDecoder().decode(StravaTokenResponse.self, from: data)
        } catch {
            throw StravaError.invalidResponse
        }
    }

    // MARK: Upload

    /// Uploads a GPX payload as a new activity. Returns the initial upload record;
    /// the activity id is populated later by ``fetchUpload(id:accessToken:)``.
    func uploadGPX(
        _ gpx: Data,
        name: String,
        description: String?,
        externalID: String,
        accessToken: String
    ) async throws -> StravaUpload {
        guard let url = URL(string: "\(apiBase)/uploads") else { throw StravaError.invalidResponse }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var fields = [
            "data_type": "gpx",
            "external_id": externalID,
            "name": name,
            "activity_type": "run"
        ]
        if let description, !description.isEmpty { fields["description"] = description }

        request.httpBody = Self.multipartBody(
            fields: fields,
            fileField: "file",
            fileName: "\(externalID).gpx",
            fileData: gpx,
            mimeType: "application/gpx+xml",
            boundary: boundary
        )

        let (data, response) = try await perform(request)
        try Self.validate(response, data: data)
        return try Self.decodeUpload(data)
    }

    /// Polls the status of a previously accepted upload.
    func fetchUpload(id: Int, accessToken: String) async throws -> StravaUpload {
        guard let url = URL(string: "\(apiBase)/uploads/\(id)") else { throw StravaError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request)
        try Self.validate(response, data: data)
        return try Self.decodeUpload(data)
    }

    /// Revokes the app's access for the connected athlete.
    func deauthorize(accessToken: String) async {
        guard let url = URL(string: "\(oauthBase)/deauthorize") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await perform(request)
    }

    // MARK: Networking

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw StravaError.networkError(error.localizedDescription)
        }
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw StravaError.invalidResponse }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw StravaError.unauthorized
        case 429:
            throw StravaError.rateLimited
        case 500...599:
            throw StravaError.serverError(statusCode: http.statusCode)
        default:
            throw StravaError.unexpectedStatusCode(http.statusCode)
        }
    }

    private static func decodeUpload(_ data: Data) throws -> StravaUpload {
        do {
            return try JSONDecoder().decode(StravaUpload.self, from: data)
        } catch {
            throw StravaError.invalidResponse
        }
    }

    private static func formEncode(_ parameters: [String: String]) -> String {
        parameters
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }

    private static func multipartBody(
        fields: [String: String],
        fileField: String,
        fileName: String,
        fileData: Data,
        mimeType: String,
        boundary: String
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        for (key, value) in fields {
            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"\(key)\"\(lineBreak)\(lineBreak)")
            body.append("\(value)\(lineBreak)")
        }

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\(lineBreak)")
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(fileData)
        body.append(lineBreak)
        body.append("--\(boundary)--\(lineBreak)")
        return body
    }
}

// MARK: - Strava response types

struct StravaTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval
    let athlete: Athlete?

    struct Athlete: Decodable, Sendable {
        let firstname: String?
        let lastname: String?
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case athlete
    }

    var athleteName: String? {
        let parts = [athlete?.firstname, athlete?.lastname].compactMap { $0 }
        let name = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

struct StravaUpload: Decodable, Sendable {
    let id: Int
    let externalID: String?
    let error: String?
    let status: String?
    let activityID: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case externalID = "external_id"
        case error
        case status
        case activityID = "activity_id"
    }
}

// MARK: - Strava credentials

/// Reads the Strava API application credentials from the bundled `Secrets.plist`.
enum StravaSecrets {

    /// Custom URL scheme used as the OAuth redirect target. Registered in Info.plist.
    static let redirectURI = "stride://strava-auth"
    static let callbackScheme = "stride"

    static var clientID: String? { value(forKey: "StravaClientID") }
    static var clientSecret: String? { value(forKey: "StravaClientSecret") }

    static var isConfigured: Bool { clientID != nil && clientSecret != nil }

    private static func value(forKey key: String) -> String? {
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let dict = NSDictionary(contentsOf: url),
            let raw = dict[key] as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("YOUR_") else { return nil }
        return trimmed
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
