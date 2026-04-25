import Foundation

#if canImport(Pulse)
import Pulse
#endif
#if canImport(PulseUI)
import PulseUI
#endif

/// Centralized bootstrap so app logs and network traffic are captured by Pulse.
enum PulseIntegrationService {

    @MainActor
    private static var isActive = false

    static var isDiagnosticsEnabled: Bool {
        #if DEBUG
        return true
        #else
        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return false }
        return receiptURL.lastPathComponent == "sandboxReceipt"
        #endif
    }

    #if canImport(Pulse)
    static func makeURLSession(configuration: URLSessionConfiguration = .default) -> any URLSessionProtocol {
        guard isDiagnosticsEnabled else {
            return URLSession(configuration: configuration)
        }
        return URLSessionProxy(configuration: configuration)
    }
    #else
    static func makeURLSession(configuration: URLSessionConfiguration = .default) -> URLSession {
        URLSession(configuration: configuration)
    }
    #endif

    @MainActor
    static func activateIfNeeded() {
        guard isDiagnosticsEnabled, !isActive else { return }
        isActive = true

        #if canImport(Pulse)
        configureLoggerStore()
        configureNetworkLogger()
        RemoteLogger.shared.initialize(store: .shared)

        #if DEBUG
        RemoteLogger.shared.isAutomaticConnectionEnabled = true
        #endif

        AppLogger.log("Pulse diagnostics activated", label: "pulse", level: .notice)
        #endif
    }

    #if canImport(Pulse)
    private static func configureLoggerStore() {
        LoggerStore.shared.configuration.sizeLimit = 64 * 1_000_000
        LoggerStore.shared.configuration.maxAge = 7 * 86_400
    }

    private static func configureNetworkLogger() {
        NetworkLogger.shared = NetworkLogger {
            $0.label = "RunningApp"
            $0.sensitiveHeaders = [
                "Authorization",
                "Cookie",
                "Set-Cookie",
                "X-API-Key",
                "X-ORS-API-Key"
            ]
            $0.sensitiveQueryItems = [
                "api_key",
                "access_token",
                "refresh_token",
                "token",
                "password"
            ]
            $0.sensitiveDataFields = [
                "apiKey",
                "accessToken",
                "refreshToken",
                "token",
                "password"
            ]
        }

        #if canImport(PulseUI)
        UserSettings.shared.mode = .network
        UserSettings.shared.allowedShareStoreOutputs = [.store, .text, .har]
        #endif
    }
    #endif
}
