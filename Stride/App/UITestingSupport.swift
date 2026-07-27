import Foundation

enum UITestingSupport {
    /// Account names written to the Keychain by the app. Listed explicitly because
    /// the Keychain is not part of the app's UserDefaults domain and survives an
    /// app delete, so it would otherwise carry state between UI-test runs.
    private static let keychainAccounts = ["orsAPIKey"]

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    /// True when this process is hosting a **unit**-test bundle.
    ///
    /// `StrideTests` runs inside the app, so `StrideApp.init()` executes before the first
    /// test does — and with no `--uitesting` flag it was building the *real* container:
    /// the on-disk store at `StrideSchema.storeURL`, with CloudKit machinery attached.
    /// Two consequences, both bad. Running unit tests read and wrote the developer's
    /// actual database, and the store the host opened was live in the same coordinator
    /// as the throwaway stores individual tests create and tear down — which is how
    /// "the store was removed from the coordinator" reached tests that never touched a
    /// store. The host's own graph is never asserted against, so in a unit-test process
    /// it is built in memory.
    ///
    /// Keyed off the environment variable XCTest sets in the host process; deliberately
    /// not a `#if DEBUG` check, since a Debug build launched normally must still open
    /// the real store.
    static var isHostingUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
