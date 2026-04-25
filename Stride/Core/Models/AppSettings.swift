import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {

    // MARK: - Stores

    private static let defaults = UserDefaults.standard
    private static let ubiquitousStore = NSUbiquitousKeyValueStore.default

    var unitPreference: UnitPreference {
        didSet {
            Self.persist(unitPreference.rawValue, forKey: Self.unitPreferenceKey)
        }
    }

    var orsAPIKey: String {
        didSet {
            Self.persist(orsAPIKey, forKey: Self.orsAPIKeyKey)
        }
    }

    var iCloudSyncEnabled: Bool {
        didSet {
            Self.persist(iCloudSyncEnabled, forKey: Self.iCloudSyncKey)
        }
    }

    var morningReminderEnabled: Bool {
        didSet {
            Self.persist(morningReminderEnabled, forKey: Self.morningReminderKey)
        }
    }

    // Internal so services can read the same key before AppSettings is created.
    static let unitPreferenceKey = "unitPreference"
    private static let orsAPIKeyKey      = "orsAPIKey"
    // Internal so AppContainer can read the same key before AppSettings is created.
    static let iCloudSyncKey = "iCloudSyncEnabled"
    static let morningReminderKey = "morningReminderEnabled"

    init() {
        Self.ubiquitousStore.synchronize()

        let raw = Self.readString(forKey: Self.unitPreferenceKey) ?? ""
        self.unitPreference = UnitPreference(rawValue: raw) ?? .metric
        self.orsAPIKey = Self.readString(forKey: Self.orsAPIKeyKey) ?? ""

        // Default to true (sync on) when the key has never been set.
        if Self.hasStoredValue(forKey: Self.iCloudSyncKey) {
            self.iCloudSyncEnabled = Self.readBool(forKey: Self.iCloudSyncKey)
        } else {
            self.iCloudSyncEnabled = true
        }

        // Default to true (reminders on) when the key has never been set.
        if Self.hasStoredValue(forKey: Self.morningReminderKey) {
            self.morningReminderEnabled = Self.readBool(forKey: Self.morningReminderKey)
        } else {
            self.morningReminderEnabled = true
        }

        Self.persist(unitPreference.rawValue, forKey: Self.unitPreferenceKey)
        Self.persist(orsAPIKey, forKey: Self.orsAPIKeyKey)
        Self.persist(iCloudSyncEnabled, forKey: Self.iCloudSyncKey)
        Self.persist(morningReminderEnabled, forKey: Self.morningReminderKey)
    }

    // MARK: - Shared readers

    static func syncedUnitPreference() -> UnitPreference {
        let raw = readString(forKey: unitPreferenceKey) ?? ""
        return UnitPreference(rawValue: raw) ?? .metric
    }

    static func syncedICloudEnabled() -> Bool {
        hasStoredValue(forKey: iCloudSyncKey) ? readBool(forKey: iCloudSyncKey) : true
    }

    // MARK: - Persistence helpers

    private static func persist(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
        ubiquitousStore.set(value, forKey: key)
        ubiquitousStore.synchronize()
    }

    private static func persist(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
        ubiquitousStore.set(value, forKey: key)
        ubiquitousStore.synchronize()
    }

    private static func hasStoredValue(forKey key: String) -> Bool {
        if ubiquitousStore.object(forKey: key) != nil {
            return true
        }
        return defaults.object(forKey: key) != nil
    }

    private static func readString(forKey key: String) -> String? {
        if let value = ubiquitousStore.string(forKey: key) {
            return value
        }
        return defaults.string(forKey: key)
    }

    private static func readBool(forKey key: String) -> Bool {
        if ubiquitousStore.object(forKey: key) != nil {
            return ubiquitousStore.bool(forKey: key)
        }
        return defaults.bool(forKey: key)
    }
}
