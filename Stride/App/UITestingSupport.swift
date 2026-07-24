import Foundation

enum UITestingSupport {
    /// Account names written to the Keychain by the app. Listed explicitly because
    /// the Keychain is not part of the app's UserDefaults domain and survives an
    /// app delete, so it would otherwise carry state between UI-test runs.
    private static let keychainAccounts = ["orsAPIKey"]

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    /// Wipes every persisted preference before the app builds its object graph.
    ///
    /// The store is already in-memory under `--uitesting`, but preferences were not:
    /// UserDefaults, iCloud key-value storage, and the Keychain all persisted across
    /// runs, so a UI test that flipped a toggle changed the starting state of every
    /// test that ran after it — and of the next run on the same simulator. Ordering
    /// matters here, which is why `StrideApp.init()` calls this before constructing
    /// `AppContainer` and `AppSettings`; both read these stores in their own init.
    static func prepareIfNeeded() {
        guard isEnabled else { return }

        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }

        let ubiquitous = NSUbiquitousKeyValueStore.default
        for key in ubiquitous.dictionaryRepresentation.keys {
            ubiquitous.removeObject(forKey: key)
        }
        ubiquitous.synchronize()

        for account in keychainAccounts {
            KeychainStore.delete(account)
        }
    }
}
