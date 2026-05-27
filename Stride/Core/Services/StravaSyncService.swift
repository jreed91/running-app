import AuthenticationServices
import Foundation
import SwiftData
import UIKit

// MARK: - StravaSyncService

/// Coordinates the Strava integration: the OAuth connect flow, token refresh, and
/// automatic GPX upload of newly synced runs.
@MainActor
final class StravaSyncService: NSObject {

    private let service: StravaService
    private let tokenStore: StravaTokenStore
    private let context: ModelContext
    private var authSession: ASWebAuthenticationSession?

    init(service: StravaService, tokenStore: StravaTokenStore, context: ModelContext) {
        self.service = service
        self.tokenStore = tokenStore
        self.context = context
        super.init()
    }

    var isConfigured: Bool { StravaSecrets.isConfigured }

    // MARK: - Connect / disconnect

    /// Presents the Strava authorization screen and stores the resulting tokens.
    func connect() async throws {
        guard
            let clientID = StravaSecrets.clientID,
            let clientSecret = StravaSecrets.clientSecret,
            let authURL = service.authorizationURL(
                clientID: clientID,
                redirectURI: StravaSecrets.redirectURI
            )
        else { throw StravaService.StravaError.notConfigured }

        let callbackURL = try await presentAuthorization(url: authURL)

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw StravaService.StravaError.invalidResponse
        }
        if components.queryItems?.first(where: { $0.name == "error" }) != nil {
            throw StravaService.StravaError.uploadFailed("Strava authorization was denied.")
        }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw StravaService.StravaError.invalidResponse
        }

        let response = try await service.exchangeCode(
            code,
            clientID: clientID,
            clientSecret: clientSecret
        )
        tokenStore.save(makeTokens(from: response, fallbackName: nil))
        AppLogger.log("Connected Strava account.", label: "Strava", level: .info)
    }

    /// Clears the stored tokens and revokes the app's access on Strava.
    func disconnect() async {
        if let accessToken = tokenStore.tokens?.accessToken {
            await service.deauthorize(accessToken: accessToken)
        }
        tokenStore.clear()
        AppLogger.log("Disconnected Strava account.", label: "Strava", level: .info)
    }

    // MARK: - Upload

    /// Uploads each run that has GPS data and has not already been pushed to Strava.
    /// No-op when Strava is not configured or the account is not connected.
    func uploadNewlySynced(_ workouts: [RunWorkout]) async {
        guard isConfigured, tokenStore.isConnected else { return }
        for workout in workouts where !workout.isUploadedToStrava {
            do {
                try await upload(workout)
            } catch StravaService.StravaError.noGPSData {
                AppLogger.log(
                    "Skipped Strava upload for run \(workout.id): no GPS route.",
                    label: "Strava",
                    level: .debug
                )
            } catch {
                AppLogger.log(
                    "Strava upload failed for run \(workout.id): \(error.localizedDescription)",
                    label: "Strava",
                    level: .error
                )
            }
        }
    }

    /// Uploads a single run. Throws on configuration, auth, or processing failures.
    func upload(_ workout: RunWorkout) async throws {
        guard isConfigured else { throw StravaService.StravaError.notConfigured }
        guard tokenStore.isConnected else { throw StravaService.StravaError.notConnected }
        guard let gpx = StravaGPXBuilder.makeGPX(for: workout) else {
            throw StravaService.StravaError.noGPSData
        }

        let accessToken = try await validAccessToken()
        let upload = try await service.uploadGPX(
            gpx,
            name: "\(workout.workoutType.displayName) Run",
            description: workout.notes,
            externalID: workout.id.uuidString,
            accessToken: accessToken
        )

        // Mark as uploaded immediately so auto-sync never pushes a duplicate, even if
        // status polling below is interrupted (app suspended, network drop).
        workout.stravaUploadID = upload.id
        workout.stravaUploadedAt = Date()
        applyUploadResult(upload, to: workout)
        try? context.save()

        await pollUploadStatus(uploadID: upload.id, workout: workout, accessToken: accessToken)
    }

    // MARK: - Tokens

    /// Returns a valid access token, refreshing it first when it is expired or expiring soon.
    private func validAccessToken() async throws -> String {
        guard let tokens = tokenStore.tokens else { throw StravaService.StravaError.notConnected }
        guard tokens.isExpired() else { return tokens.accessToken }

        guard
            let clientID = StravaSecrets.clientID,
            let clientSecret = StravaSecrets.clientSecret
        else { throw StravaService.StravaError.notConfigured }

        let response = try await service.refreshTokens(
            refreshToken: tokens.refreshToken,
            clientID: clientID,
            clientSecret: clientSecret
        )
        let refreshed = makeTokens(from: response, fallbackName: tokens.athleteName)
        tokenStore.save(refreshed)
        return refreshed.accessToken
    }

    private func makeTokens(
        from response: StravaTokenResponse,
        fallbackName: String?
    ) -> StravaTokens {
        StravaTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date(timeIntervalSince1970: response.expiresAt),
            athleteName: response.athleteName ?? fallbackName
        )
    }

    // MARK: - Status polling

    private func pollUploadStatus(uploadID: Int, workout: RunWorkout, accessToken: String) async {
        for attempt in 0..<4 {
            try? await Task.sleep(nanoseconds: UInt64(2_000_000_000 * (attempt + 1)))
            guard let upload = try? await service.fetchUpload(id: uploadID, accessToken: accessToken) else {
                continue
            }
            applyUploadResult(upload, to: workout)
            try? context.save()
            if workout.stravaActivityID != nil { return }
        }
    }

    /// Reflects a Strava upload record onto the run, recovering the activity id from a
    /// duplicate-upload error when Strava already has the activity.
    private func applyUploadResult(_ upload: StravaUpload, to workout: RunWorkout) {
        if let activityID = upload.activityID {
            workout.stravaActivityID = activityID
        } else if let error = upload.error,
                  let duplicateID = Self.parseDuplicateActivityID(from: error) {
            workout.stravaActivityID = duplicateID
        }
    }

    /// Extracts the activity id from Strava's "duplicate of activity <id>" error string.
    nonisolated static func parseDuplicateActivityID(from error: String) -> Int? {
        guard error.lowercased().contains("duplicate") else { return nil }
        let digits = error.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return digits.last
    }

    // MARK: - Authorization presentation

    private func presentAuthorization(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: StravaSecrets.callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: StravaService.StravaError.invalidResponse)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            if !session.start() {
                continuation.resume(throwing: StravaService.StravaError.notConfigured)
            }
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension StravaSyncService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}
