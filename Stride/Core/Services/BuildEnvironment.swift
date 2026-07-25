import Foundation

// MARK: - BuildEnvironment

/// How this binary was distributed, and what that means for what the app exposes.
///
/// Formerly `DataMigrationService`, which contained no migration logic at all — the
/// name promised something the type never did, and the same receipt check lived a
/// second time in `PulseIntegrationService` (N27). Both now read this.
enum BuildEnvironment {

    /// `true` when the running binary was distributed via TestFlight.
    ///
    /// TestFlight builds carry a `sandboxReceipt` at the App Store receipt URL.
    /// App Store builds carry a plain `receipt`; debug / simulator builds have no
    /// receipt file at all.
    static var isTestFlight: Bool {
        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return false }
        return receiptURL.lastPathComponent == "sandboxReceipt"
    }

    /// Whether to surface diagnostic affordances (CloudKit debug data, notification
    /// test harness) that must never reach an App Store build.
    static var showsTestFlightDiagnostics: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        isTestFlight
        #endif
    }
}
