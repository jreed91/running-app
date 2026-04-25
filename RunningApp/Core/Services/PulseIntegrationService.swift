import Foundation

#if canImport(Pulse)
import Pulse
#endif
#if canImport(PulseProxy)
import PulseProxy
#endif

/// Enables Pulse only for TestFlight builds so beta testers can capture
/// and share network logs without exposing diagnostics in App Store releases.
@MainActor
enum PulseIntegrationService {

    private static let hasEnabledKey = "PulseIntegrationService.hasEnabled"

    static func activateIfNeeded() {
        guard DataMigrationService.isTestFlight else { return }

        #if canImport(Pulse)
        RemoteLogger.shared.isAutomaticConnectionEnabled = true
        LoggerStore.shared.storeMessage(
            label: "pulse",
            level: .notice,
            message: "Pulse integration enabled for TestFlight build"
        )
        #endif

        #if canImport(PulseProxy)
        // Keep this idempotent because app launch tasks can run multiple times.
        guard !UserDefaults.standard.bool(forKey: hasEnabledKey) else { return }
        NetworkLogger.enableProxy()
        UserDefaults.standard.set(true, forKey: hasEnabledKey)
        #endif
    }
}
