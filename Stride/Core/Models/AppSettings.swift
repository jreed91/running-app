import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {

    // MARK: - Stores

    private static let defaults = UserDefaults.standard
    private static let ubiquitousStore = NSUbiquitousKeyValueStore.default

    /// API keys should remain local-only and never sync through iCloud key-value storage.
    private static let localOnlyStringKeys: Set<String> = [
        aiAPIKeyKey
    ]

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

    var aiAPIKey: String {
        didSet {
            Self.persist(aiAPIKey, forKey: Self.aiAPIKeyKey)
        }
    }

    var aiInsightsEnabled: Bool {
        didSet {
            Self.persist(aiInsightsEnabled, forKey: Self.aiInsightsEnabledKey)
        }
    }

    var aiProvider: AIProvider {
        didSet {
            Self.persist(aiProvider.rawValue, forKey: Self.aiProviderKey)
        }
    }

    var aiModelOverride: String {
        didSet {
            Self.persist(aiModelOverride, forKey: Self.aiModelOverrideKey)
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
    private static let aiAPIKeyKey       = "aiAPIKey"
    private static let aiInsightsEnabledKey = "aiInsightsEnabled"
    private static let aiProviderKey     = "aiProvider"
    private static let aiModelOverrideKey = "aiModelOverride"
    // Internal so AppContainer can read the same key before AppSettings is created.
    static let iCloudSyncKey = "iCloudSyncEnabled"
    static let morningReminderKey = "morningReminderEnabled"

    init() {
        Self.ubiquitousStore.synchronize()
        Self.removeLocalOnlyValuesFromUbiquitousStore()

        let raw = Self.readString(forKey: Self.unitPreferenceKey) ?? ""
        self.unitPreference = UnitPreference(rawValue: raw) ?? .metric
        self.orsAPIKey = Self.readString(forKey: Self.orsAPIKeyKey) ?? ""
        self.aiAPIKey = Self.readString(forKey: Self.aiAPIKeyKey) ?? ""

        if Self.hasStoredValue(forKey: Self.aiInsightsEnabledKey) {
            self.aiInsightsEnabled = Self.readBool(forKey: Self.aiInsightsEnabledKey)
        } else {
            self.aiInsightsEnabled = false
        }

        let providerRaw = Self.readString(forKey: Self.aiProviderKey) ?? ""
        self.aiProvider = AIProvider(rawValue: providerRaw) ?? .openAI
        self.aiModelOverride = Self.readString(forKey: Self.aiModelOverrideKey) ?? ""

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
        Self.persist(aiAPIKey, forKey: Self.aiAPIKeyKey)
        Self.persist(aiInsightsEnabled, forKey: Self.aiInsightsEnabledKey)
        Self.persist(aiProvider.rawValue, forKey: Self.aiProviderKey)
        Self.persist(aiModelOverride, forKey: Self.aiModelOverrideKey)
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

        guard localOnlyStringKeys.contains(key) == false else {
            ubiquitousStore.removeObject(forKey: key)
            ubiquitousStore.synchronize()
            return
        }

        ubiquitousStore.set(value, forKey: key)
        ubiquitousStore.synchronize()
    }

    private static func persist(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
        ubiquitousStore.set(value, forKey: key)
        ubiquitousStore.synchronize()
    }


    private static func removeLocalOnlyValuesFromUbiquitousStore() {
        var removed = false
        for key in localOnlyStringKeys where ubiquitousStore.object(forKey: key) != nil {
            ubiquitousStore.removeObject(forKey: key)
            removed = true
        }

        if removed {
            ubiquitousStore.synchronize()
        }
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
