import Foundation

// MARK: - DataMigrationService

enum DataMigrationService {

    // MARK: - TestFlight detection

    /// `true` when the running binary was distributed via TestFlight.
    ///
    /// TestFlight builds carry a `sandboxReceipt` at the App Store receipt URL.
    /// App Store builds carry a plain `receipt`; debug / simulator builds have no
    /// receipt file at all.
    static var isTestFlight: Bool {
        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return false }
        return receiptURL.lastPathComponent == "sandboxReceipt"
    }

    static var showsTestFlightDiagnostics: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        isTestFlight
        #endif
    }
}
