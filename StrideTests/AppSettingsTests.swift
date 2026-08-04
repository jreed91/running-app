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

        // In-memory defaults still resolve as expected. Units follow the device rather
        // than a hardcoded metric assumption (U10), so the expectation does too.
        #expect(settings.unitPreference == UnitPreference.localeDefault)
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

    // MARK: - Walk import (N38)

    @Test("Fresh install imports walks without seeding iCloud")
    func walkImportDefaultsOnWithoutSeeding() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()

        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        #expect(settings.walkImportEnabled)
        #expect(ubiquitous.has(AppSettings.walkImportKey) == false)
        #expect(defaults.has(AppSettings.walkImportKey) == false)
    }

    @Test("Turning walk import off round-trips through both stores")
    func walkImportChangeSyncs() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        settings.walkImportEnabled = false

        #expect(defaults.object(forKey: AppSettings.walkImportKey) as? Bool == false)
        #expect(ubiquitous.object(forKey: AppSettings.walkImportKey) as? Bool == false)
    }

    @Test("A stored walk-import choice is read back on launch")
    func walkImportReadOnLaunch() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        ubiquitous.set(false, forKey: AppSettings.walkImportKey)

        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        #expect(settings.walkImportEnabled == false)
    }

    // MARK: - Weekly goal (B4)

    @Test("Fresh install defaults the weekly goal to 20 km without seeding iCloud")
    func weeklyGoalDefaultsWithoutSeeding() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()

        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        #expect(settings.weeklyGoalMeters == AppSettings.defaultWeeklyGoalMeters)
        #expect(ubiquitous.has(AppSettings.weeklyGoalMetersKey) == false)
        #expect(defaults.has(AppSettings.weeklyGoalMetersKey) == false)
    }

    @Test("Changing the weekly goal round-trips through both stores")
    func weeklyGoalChangeSyncs() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        settings.weeklyGoalMeters = 42_000

        #expect(defaults.object(forKey: AppSettings.weeklyGoalMetersKey) as? Double == 42_000)
        #expect(ubiquitous.object(forKey: AppSettings.weeklyGoalMetersKey) as? Double == 42_000)
    }

    @Test("A stored weekly goal is read back on launch")
    func weeklyGoalReadOnLaunch() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        ubiquitous.set(35_000.0, forKey: AppSettings.weeklyGoalMetersKey)

        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        #expect(settings.weeklyGoalMeters == 35_000)
    }

    // MARK: - Spoken splits (U4)

    @Test("Spoken splits are off on a fresh install, and nothing is seeded")
    func spokenSplitsDefaultOff() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()

        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        // Off by default: this is the setting that talks over the runner's music.
        #expect(settings.spokenSplitsEnabled == false)
        #expect(ubiquitous.has(AppSettings.spokenSplitsKey) == false)
        #expect(defaults.has(AppSettings.spokenSplitsKey) == false)
    }

    @Test("Turning spoken splits on round-trips through both stores")
    func spokenSplitsChangeSyncs() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        settings.spokenSplitsEnabled = true

        #expect(defaults.bool(forKey: AppSettings.spokenSplitsKey) == true)
        #expect(ubiquitous.bool(forKey: AppSettings.spokenSplitsKey) == true)
    }

    @Test("A stored spoken-splits preference is read back on launch")
    func spokenSplitsReadOnLaunch() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        ubiquitous.set(true, forKey: AppSettings.spokenSplitsKey)

        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        #expect(settings.spokenSplitsEnabled == true)
    }

    // MARK: - M15: mid-session changes arriving from another device

    @Test("A value that lands in iCloud while running is adopted")
    func externalChangeIsAdopted() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)
        #expect(settings.unitPreference == UnitPreference.localeDefault)

        // Another device switches units; iCloud KVS delivers it mid-session. The incoming
        // value is whichever one this device is *not* already on, so the test proves
        // adoption on any locale (U10).
        let incomingUnit: UnitPreference = UnitPreference.localeDefault == .metric ? .imperial : .metric
        ubiquitous.set(incomingUnit.rawValue, forKey: AppSettings.unitPreferenceKey)
        ubiquitous.set(50_000.0, forKey: AppSettings.weeklyGoalMetersKey)
        ubiquitous.set(false, forKey: AppSettings.morningReminderKey)
        settings.applyExternalValues()

        #expect(settings.unitPreference == incomingUnit)
        #expect(settings.weeklyGoalMeters == 50_000)
        #expect(settings.morningReminderEnabled == false)
    }

    @Test("An external change with nothing new leaves settings alone")
    func externalChangeWithoutNewValuesIsANoOp() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)

        settings.weeklyGoalMeters = 30_000
        settings.applyExternalValues()

        #expect(settings.weeklyGoalMeters == 30_000)
        #expect(settings.unitPreference == UnitPreference.localeDefault)
    }

    @Test("The device-local sync toggle is never changed by a remote value (M16)")
    func externalChangeDoesNotFlipTheSyncToggle() {
        let defaults = InMemoryStore()
        let ubiquitous = InMemoryStore()
        let settings = AppSettings(defaults: defaults, ubiquitous: ubiquitous)
        #expect(settings.iCloudSyncEnabled == true)

        // Even if a stale copy of the toggle somehow reaches iCloud KVS, turning sync
        // off on one device must not cascade and disable persistence everywhere.
        ubiquitous.set(false, forKey: AppSettings.iCloudSyncKey)
        settings.applyExternalValues()

        #expect(settings.iCloudSyncEnabled == true)
    }
}
