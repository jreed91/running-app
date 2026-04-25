import Foundation

#if canImport(Pulse)
import Pulse
#endif
#if canImport(PulseProxy)
import PulseProxy
#endif

/// Centralized bootstrap so app logs and network traffic are captured by Pulse.
@MainActor
enum PulseIntegrationService {

    private static let hasEnabledKey = "PulseIntegrationService.hasEnabled"

    static func activateIfNeeded() {
        #if canImport(Pulse)
        RemoteLogger.shared.isAutomaticConnectionEnabled = true
        LoggerStore.shared.storeMessage(
            label: "pulse",
            level: .notice,
            message: "Pulse integration activated"
        )
        #endif

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
