import Foundation
import Observation

/// Connects Stride to the runner's Strava account and sends finished runs there.
///
/// This type holds the *plumbing* — the Keychain, the network calls, and their order. What
/// the requests look like and how Strava's replies are read lives in ``StravaAPI``, which
/// is pure and tested.
///
/// Rules a change here has to keep:
///
/// - **Tokens live in the Keychain, on this device only** (`KeychainStore`, the same place
///   the ORS key lives). A connection is per device, so the auto-upload switch and the
///   record of what was uploaded are device-local `UserDefaults` too — never iCloud KVS,
///   or a second phone would think it was connected with no token to show for it.
/// - **Only runs Stride recorded upload on their own.** A run imported from Apple Health
///   was recorded by a watch or another app that very likely sends it to Strava already;
///   those can still be sent by hand from the run's share menu.
/// - **Walks never go.** They are history, not training (see AGENTS.md → Walking
///   workouts), and Strava gets them from Apple Health if the runner wants them there.
@Observable
@MainActor
final class StravaService {

    // MARK: - Types

    enum StravaError: LocalizedError, Equatable {
        case notConfigured
        case notConnected
        case missingPermission
        case authorizationFailed
        case sessionExpired
        case rateLimited
        case notARun
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return String(localized: "Strava isn't available in this build.", comment: "Strava error")
            case .notConnected:
                return String(localized: "Connect Strava in Settings first.", comment: "Strava error")
            case .missingPermission:
                return String(
                    localized: "Stride needs permission to upload your activities. Connect again and leave \"Upload your activities\" ticked.",
                    comment: "Strava error when the athlete unticked the upload scope"
                )
            case .authorizationFailed:
                return String(localized: "Strava didn't finish connecting. Try again.", comment: "Strava error")
            case .sessionExpired:
                return String(
                    localized: "Stride's access to Strava ended. Reconnect Strava in Settings.",
                    comment: "Strava error when the token was revoked"
                )
            case .rateLimited:
                return String(
                    localized: "Strava is busy right now. Try again in a few minutes.",
                    comment: "Strava error on HTTP 429"
                )
            case .notARun:
                return String(localized: "Only runs can be uploaded to Strava.", comment: "Strava error")
            case .server(let message):
                return String(localized: "Strava said: \(message)", comment: "Strava error with the server's message")
            }
        }
    }

    enum UploadState: Equatable {
        case uploading
        /// Strava accepted the file but had not finished reading it when Stride stopped
        /// asking. It appears on Strava by itself; another tap resolves it to its id.
        case processing
        case uploaded(activityID: Int64?)
        case failed(String)
    }

    /// The account on the other end, shown in Settings.
    struct Connection: Codable, Equatable {
        var athleteName: String?
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    // MARK: - State

    let credentials: StravaAPI.Credentials?
    var isConfigured: Bool { credentials != nil }

    private(set) var connection: Connection?
    var isConnected: Bool { connection != nil }

    /// Send each run Stride records to Strava as soon as it is saved. On by default once
    /// connected: connecting at all is the runner asking for their runs to go there.
    var uploadsAutomatically: Bool {
        didSet { defaults.set(uploadsAutomatically, forKey: Self.autoUploadKey) }
    }

    /// Per-run state for the runs touched this session, for the run screen's menu.
    private(set) var uploadStates: [UUID: UploadState] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var refreshTask: Task<Connection, Error>?

    private static let tokensAccount = "strava.connection"
    private static let autoUploadKey = "strava.uploadsAutomatically"
    private static let uploadedKey = "strava.uploadedActivities"

    /// How often, and how many times, to ask whether Strava has finished reading a file.
    /// Strava's docs put a typical upload at about eight seconds and ask clients to poll
    /// no more than once a second.
    private static let pollInterval: Duration = .seconds(2)
    private static let pollAttempts = 10

    init(
        credentials: StravaAPI.Credentials? = StravaAPI.Credentials.from(infoDictionary: Bundle.main.infoDictionary),
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.defaults = defaults
        self.session = session
        self.uploadsAutomatically = defaults.object(forKey: Self.autoUploadKey) as? Bool ?? true
        self.connection = KeychainStore.string(for: Self.tokensAccount)
            .flatMap { Data($0.utf8).decode(Connection.self) }
    }

    // MARK: - Connecting

    /// The page to show in a web-authentication session, and the `state` its redirect
    /// must carry back to `completeAuthorization`.
    func beginAuthorization() throws -> (url: URL, state: String) {
        guard let credentials else { throw StravaError.notConfigured }
        let state = UUID().uuidString
        return (StravaAPI.authorizationURL(clientID: credentials.clientID, state: state), state)
    }

    func completeAuthorization(callbackURL: URL, expectedState: String) async throws {
        guard let credentials else { throw StravaError.notConfigured }
        switch StravaAPI.parseCallback(callbackURL, expectedState: expectedState) {
        case .denied:
            return
        case .missingScope:
            throw StravaError.missingPermission
        case .invalid:
            throw StravaError.authorizationFailed
        case .code(let code):
            let token: StravaAPI.TokenResponse = try await send(
                StravaAPI.tokenExchangeRequest(code: code, credentials: credentials)
            )
            store(Connection(
                athleteName: token.athlete?.displayName,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: Date(timeIntervalSince1970: token.expiresAt)
            ))
            AppLogger.log("Connected to Strava", label: "Strava")
        }
    }

    /// Revokes Stride's access on Strava and forgets the tokens. The forgetting happens
    /// whether or not Strava answers: a runner who pressed Disconnect offline still means it.
    func disconnect() async {
        if let token = try? await validAccessToken() {
            do {
                _ = try await session.data(for: StravaAPI.deauthorizeRequest(accessToken: token))
            } catch {
                AppLogger.log(
                    "Strava deauthorize failed: \(error.localizedDescription)",
                    label: "Strava",
                    level: .error
                )
            }
        }
        store(nil)
        uploadStates = [:]
        AppLogger.log("Disconnected from Strava", label: "Strava")
    }

    // MARK: - Uploading

    /// Whether this run can be sent at all: a run, not a walk, with something to report.
    static func canUpload(_ workout: RunWorkout) -> Bool {
        !workout.isWalk && workout.durationSeconds > 0
    }

    /// The Strava activity this run became, when this device sent it (or found it there).
    func activityID(for workout: RunWorkout) -> Int64? {
        if case .uploaded(let id?) = uploadStates[workout.id] { return id }
        return uploadedActivities[workout.id.uuidString]
    }

    func state(for workout: RunWorkout) -> UploadState? {
        if let state = uploadStates[workout.id] { return state }
        if let id = uploadedActivities[workout.id.uuidString] { return .uploaded(activityID: id) }
        return nil
    }

    /// Forgets a failure once the runner has seen it, so the menu offers the upload again.
    func clearFailure(for workout: RunWorkout) {
        if case .failed = uploadStates[workout.id] { uploadStates[workout.id] = nil }
    }

    /// Called once a run Stride recorded has been saved. Does nothing unless the runner
    /// is connected and left automatic uploads on, and nothing for a run under the effort
    /// floor: a mis-tapped start is saved so it can be deleted, not posted to a public feed.
    func uploadFinishedRunIfEnabled(_ workout: RunWorkout) async {
        guard isConnected, uploadsAutomatically, Self.canUpload(workout),
              RunEffortPolicy.isRealRun(
                  distanceMeters: workout.distanceMeters,
                  durationSeconds: workout.durationSeconds
              )
        else { return }
        await upload(workout)
    }

    /// Sends one run and records how it went in `uploadStates`. Never throws: the run
    /// screen reads the outcome from the state, whichever path started the upload.
    func upload(_ workout: RunWorkout) async {
        let runID = workout.id
        if uploadStates[runID] == .uploading { return }
        uploadStates[runID] = .uploading
        do {
            let result = try await transmit(workout)
            uploadStates[runID] = result
            if case .uploaded(let id?) = result { recordUpload(runID: runID, activityID: id) }
        } catch {
            AppLogger.log(
                "Strava upload of run \(runID) failed: \(error.localizedDescription)",
                label: "Strava",
                level: .error
            )
            uploadStates[runID] = .failed(error.localizedDescription)
        }
    }

    private func transmit(_ workout: RunWorkout) async throws -> UploadState {
        guard Self.canUpload(workout) else { throw StravaError.notARun }
        let draft = StravaActivityDraft.make(for: workout)
        let token = try await validAccessToken()

        // A run with no route — a treadmill run, or one that never got a GPS fix — has no
        // file to send, so it goes in as a manual activity with its distance and time.
        guard let gpx = GPXExport.document(for: workout) else {
            let activity: StravaAPI.ActivityResponse = try await send(
                StravaAPI.createActivityRequest(draft: draft, accessToken: token)
            )
            return .uploaded(activityID: activity.id)
        }

        var upload: StravaAPI.UploadResponse = try await send(StravaAPI.uploadRequest(
            gpx: Data(gpx.utf8),
            fileName: GPXExport.fileName(for: workout),
            draft: draft,
            accessToken: token
        ))
        for attempt in 0...Self.pollAttempts {
            switch StravaAPI.outcome(of: upload) {
            case .ready(let id), .duplicate(let id?):
                return .uploaded(activityID: id)
            case .duplicate(nil):
                return .uploaded(activityID: nil)
            case .failed(let message):
                throw StravaError.server(message)
            case .processing:
                guard attempt < Self.pollAttempts else { return .processing }
                try await Task.sleep(for: Self.pollInterval)
                upload = try await send(StravaAPI.uploadStatusRequest(uploadID: upload.id, accessToken: token))
            }
        }
        return .processing
    }

    // MARK: - Tokens

    /// An access token good for at least another minute, refreshing it first if not.
    /// Concurrent callers share one refresh: Strava can rotate the refresh token, and two
    /// refreshes racing with the same old one would leave one of them holding a dead token.
    private func validAccessToken() async throws -> String {
        guard let credentials else { throw StravaError.notConfigured }
        guard let current = connection else { throw StravaError.notConnected }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }

        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { [session] () async throws -> Connection in
            let request = StravaAPI.refreshRequest(refreshToken: current.refreshToken, credentials: credentials)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw status == 400 || status == 401 ? StravaError.sessionExpired : StravaError.server("HTTP \(status)")
            }
            let token = try StravaAPI.decoder.decode(StravaAPI.TokenResponse.self, from: data)
            var refreshed = current
            refreshed.accessToken = token.accessToken
            refreshed.refreshToken = token.refreshToken
            refreshed.expiresAt = Date(timeIntervalSince1970: token.expiresAt)
            return refreshed
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            store(refreshed)
            return refreshed.accessToken
        } catch StravaError.sessionExpired {
            store(nil)
            throw StravaError.sessionExpired
        }
    }

    private func store(_ connection: Connection?) {
        self.connection = connection
        let json = connection
            .flatMap { Data.encoded($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        KeychainStore.set(json, for: Self.tokensAccount)
    }

    // MARK: - Network

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return try StravaAPI.decoder.decode(Response.self, from: data)
        case 401:
            // Revoked from strava.com, or the token was refreshed on another path and this
            // one is stale. Either way the stored connection no longer works.
            store(nil)
            throw StravaError.sessionExpired
        case 429:
            throw StravaError.rateLimited
        default:
            let message = (try? StravaAPI.decoder.decode(StravaAPI.Fault.self, from: data))?.message
            throw StravaError.server(message ?? "HTTP \(status)")
        }
    }

    // MARK: - Upload record

    /// Run id → Strava activity id, so a run shows "View on Strava" after a relaunch.
    private var uploadedActivities: [String: Int64] {
        (defaults.dictionary(forKey: Self.uploadedKey) as? [String: Int64]) ?? [:]
    }

    private func recordUpload(runID: UUID, activityID: Int64) {
        var record = uploadedActivities
        record[runID.uuidString] = activityID
        defaults.set(record, forKey: Self.uploadedKey)
    }
}
