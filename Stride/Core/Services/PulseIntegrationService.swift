import Foundation

#if canImport(Pulse)
import Pulse
typealias StrideURLSessionProtocol = Pulse.URLSessionProtocol
#else
protocol StrideURLSessionProtocol: Sendable {
    func data(for request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse)
    func bytes(for request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> (URLSession.AsyncBytes, URLResponse)
}

extension StrideURLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await bytes(for: request, delegate: nil)
    }
}

extension URLSession: StrideURLSessionProtocol {}
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

    static func makeURLSession(configuration: URLSessionConfiguration = .default) -> any StrideURLSessionProtocol {
        #if canImport(Pulse)
        guard isDiagnosticsEnabled else {
            return URLSession(configuration: configuration)
        }
        return URLSessionProxy(configuration: configuration)
        #else
        return URLSession(configuration: configuration)
        #endif
    }

    static func makeNetworkLoggingDelegate() -> (any URLSessionTaskDelegate)? {
        #if canImport(Pulse)
        guard isDiagnosticsEnabled else { return nil }
        return URLSessionProxyDelegate(logger: .shared)
        #else
        return nil
        #endif
    }

    static func storeCompletedNetworkRequest(
        _ request: URLRequest,
        response: URLResponse?,
        error: Error?,
        data: Data?,
        label: String,
        taskDescription: String
    ) {
        #if canImport(Pulse)
        guard isDiagnosticsEnabled else { return }
        LoggerStore.shared.storeRequest(
            request,
            response: response,
            error: error,
            data: data,
            label: label,
            taskDescription: taskDescription
        )
        #endif
    }

    @MainActor
    static func activateIfNeeded() {
        guard isDiagnosticsEnabled, !isActive else { return }
        isActive = true

        #if canImport(Pulse)
        configureLoggerStore()
        configureNetworkLogger()

        // Remote logging advertises the app over Bonjour (`_pulse._tcp`). Restrict
        // it to local development so a TestFlight tester's device never broadcasts
        // its diagnostics on the local network, and the dev-only
        // NSLocalNetworkUsageDescription is never exercised in shipped builds (S4).
        // The on-disk store above still captures diagnostics for TestFlight QA.
        #if DEBUG
        RemoteLogger.shared.initialize(store: .shared)
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
            $0.label = "Stride"
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
