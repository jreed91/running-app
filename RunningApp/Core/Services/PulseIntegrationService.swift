import Foundation

#if canImport(PulseProxy)
import Pulse
import PulseProxy
#endif

/// Enables Pulse only for TestFlight builds so beta testers can capture
/// and share network logs without exposing diagnostics in App Store releases.
@MainActor
enum PulseIntegrationService {

    private static let hasEnabledKey = "PulseIntegrationService.hasEnabled"

    static func activateIfNeeded() {
        guard DataMigrationService.isTestFlight else { return }

        #if canImport(PulseProxy)
        // Keep this idempotent because app launch tasks can run multiple times.
        guard !UserDefaults.standard.bool(forKey: hasEnabledKey) else { return }
        NetworkLogger.enableProxy()
        UserDefaults.standard.set(true, forKey: hasEnabledKey)
        #endif
    }
}
