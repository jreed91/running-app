import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {

    // MARK: - Stores

    private static let defaults = UserDefaults.standard
    private static let ubiquitousStore = NSUbiquitousKeyValueStore.default

    /// String keys that must stay local-only and never sync through iCloud key-value
    /// storage. AI coaching no longer uses any API key (it runs on Apple's Foundation
    /// Models), so this is currently empty; the machinery is kept for future secrets.
    private static let localOnlyStringKeys: Set<String> = []

    var unitPreference: UnitPreference {
        didSet {
            Self.persist(unitPreference.rawValue, forKey: Self.unitPreferenceKey)
        }
    }

    /// OpenRouteService token. Backed by the Keychain (see `KeychainStore`) — never
    /// written to UserDefaults or synced through iCloud KVS, unlike the other settings (S1).
    var orsAPIKey: String {
        didSet {
            KeychainStore.set(orsAPIKey, for: Self.orsAPIKeyAccount)
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
    /// Legacy UserDefaults/iCloud-KVS key for the ORS token. Retained only so the
    /// one-time migration in `loadORSAPIKey()` can find and purge a plaintext copy.
    private static let orsAPIKeyKey      = "orsAPIKey"
    /// Keychain account under which the ORS token now lives.
    private static let orsAPIKeyAccount  = "orsAPIKey"
    private static let aiInsightsEnabledKey = "aiInsightsEnabled"
    private static let aiProviderKey     = "aiProvider"
    // Internal so AppContainer can read the same key before AppSettings is created.
    static let iCloudSyncKey = "iCloudSyncEnabled"
    static let morningReminderKey = "morningReminderEnabled"

    init() {
        Self.ubiquitousStore.synchronize()
        Self.removeLocalOnlyValuesFromUbiquitousStore()

        let raw = Self.readString(forKey: Self.unitPreferenceKey) ?? ""
        self.unitPreference = UnitPreference(rawValue: raw) ?? .metric
        self.orsAPIKey = Self.loadORSAPIKey()

        if Self.hasStoredValue(forKey: Self.aiInsightsEnabledKey) {
            self.aiInsightsEnabled = Self.readBool(forKey: Self.aiInsightsEnabledKey)
        } else {
            self.aiInsightsEnabled = false
        }

        let providerRaw = Self.readString(forKey: Self.aiProviderKey) ?? ""
        // New installs default to Apple's on-device model: no API key, private, free.
        self.aiProvider = AIProvider(rawValue: providerRaw) ?? .appleOnDevice

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
        Self.persist(aiInsightsEnabled, forKey: Self.aiInsightsEnabledKey)
        Self.persist(aiProvider.rawValue, forKey: Self.aiProviderKey)
        Self.persist(iCloudSyncEnabled, forKey: Self.iCloudSyncKey)
        Self.persist(morningReminderEnabled, forKey: Self.morningReminderKey)
    }

    // MARK: - AI readiness

    /// AI coaching runs on Apple's on-device / Private Cloud Compute models, which
    /// require no API key, so the provider is always "credentialed". Kept as a named
    /// property so call sites read intentionally and to leave room for future gating
    /// (e.g. device eligibility) without touching every caller.
    var hasAICredentials: Bool { true }

    /// True when AI Coach is enabled and the provider is ready to use.
    var isAICoachReady: Bool {
        aiInsightsEnabled && hasAICredentials
    }

    /// Reads the ORS token from the Keychain, migrating any plaintext copy that an older
    /// build left in UserDefaults / iCloud KVS into the Keychain and purging it (S1).
    private static func loadORSAPIKey() -> String {
        if let keychainValue = KeychainStore.string(for: orsAPIKeyAccount), !keychainValue.isEmpty {
            // A synced copy may still linger from a pre-migration build on another device.
            purgeLegacyORSAPIKey()
            return keychainValue
        }

        let legacy = readString(forKey: orsAPIKeyKey) ?? ""
        if !legacy.isEmpty {
            KeychainStore.set(legacy, for: orsAPIKeyAccount)
        }
        purgeLegacyORSAPIKey()
        return legacy
    }

    private static func purgeLegacyORSAPIKey() {
        defaults.removeObject(forKey: orsAPIKeyKey)
        ubiquitousStore.removeObject(forKey: orsAPIKeyKey)
        ubiquitousStore.synchronize()
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
