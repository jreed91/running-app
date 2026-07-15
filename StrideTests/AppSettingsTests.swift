import Foundation
import Testing
@testable import Stride

/// In-memory `KeyValueStore` double so `AppSettings` persistence can be exercised without
/// touching the process-wide `UserDefaults` / iCloud key-value stores.
private final class InMemoryStore: KeyValueStore {
    private(set) var storage: [String: Any] = [:]

    func object(forKey key: String) -> Any? { storage[key] }
    func string(forKey key: String) -> String? { storage[key] as? String }
    func bool(forKey key: String) -> Bool { storage[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        if let value {
            storage[key] = value
        } else {
            storage[key] = nil
        }
    }
    func removeObject(forKey key: String) { storage[key] = nil }
    func synchronizeStore() {}

    func has(_ key: String) -> Bool { storage[key] != nil }
}

@MainActor
struct AppSettingsTests {

    // MARK: - M15: no first-launch clobber

    @Test("Fresh install does not seed any setting into the iCloud store")
    func freshInstallDoesNotSeedICloudStore() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()

        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        // In-memory defaults still resolve as expected...
        #expect(settings.unitPreference == .metric)
        #expect(settings.iCloudSyncEnabled == true)
        #expect(settings.morningReminderEnabled == true)

        // ...but nothing was written to iCloud KVS, so a not-yet-delivered remote value
        // cannot be clobbered by our defaults (M15).
        #expect(ubiquitous.has(AppSettings.unitPreferenceKey) == false)
        #expect(ubiquitous.has("aiInsightsEnabled") == false)
        #expect(ubiquitous.has(AppSettings.morningReminderKey) == false)
    }

    @Test("A value already present only in iCloud is honored and not overwritten")
    func remoteValueIsHonoredOnLaunch() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        ubiquitous.set(UnitPreference.imperial.rawValue, forKey: AppSettings.unitPreferenceKey)

        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        #expect(settings.unitPreference == .imperial)
        // The remote value survives (it was stored, so write-back promotes it locally too).
        #expect(ubiquitous.string(forKey: AppSettings.unitPreferenceKey) == UnitPreference.imperial.rawValue)
        #expect(defaults.string(forKey: AppSettings.unitPreferenceKey) == UnitPreference.imperial.rawValue)
    }

    @Test("A synced key already present still round-trips through iCloud on change")
    func syncedKeyStillSyncs() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        settings.unitPreference = .imperial

        #expect(ubiquitous.string(forKey: AppSettings.unitPreferenceKey) == UnitPreference.imperial.rawValue)
        #expect(defaults.string(forKey: AppSettings.unitPreferenceKey) == UnitPreference.imperial.rawValue)
    }

    // MARK: - M16: device-local iCloud-sync toggle

    @Test("Toggling iCloud sync writes to defaults only, never to iCloud KVS")
    func syncToggleIsDeviceLocal() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        settings.iCloudSyncEnabled = false

        #expect(defaults.bool(forKey: AppSettings.iCloudSyncKey) == false)
        #expect(ubiquitous.has(AppSettings.iCloudSyncKey) == false)
    }

    @Test("A stale synced sync-toggle value is purged from iCloud on launch")
    func staleSyncedToggleIsPurgedOnLaunch() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        // Simulate a pre-M16 build that synced the toggle through iCloud KVS.
        ubiquitous.set(true, forKey: AppSettings.iCloudSyncKey)
        defaults.set(false, forKey: AppSettings.iCloudSyncKey)

        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        // The device-local value (UserDefaults) wins and the synced copy is removed.
        #expect(settings.iCloudSyncEnabled == false)
        #expect(ubiquitous.has(AppSettings.iCloudSyncKey) == false)
    }
}
