import Foundation
import Observation

/// Minimal key-value store abstraction so `AppSettings` persistence can be exercised with
/// in-memory doubles in unit tests instead of the process-wide `UserDefaults` / iCloud
/// key-value stores.
protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    /// Flushes pending writes. No-op for `UserDefaults` (whose `synchronize()` is deprecated
    /// and unnecessary); forwards to `synchronize()` for the iCloud key-value store.
    func synchronizeStore()
}

extension UserDefaults: KeyValueStore {
    func synchronizeStore() {}
}

extension NSUbiquitousKeyValueStore: KeyValueStore {
    func synchronizeStore() { synchronize() }
}

@Observable
@MainActor
final class AppSettings {

    // MARK: - Stores

    @ObservationIgnored private let defaults: KeyValueStore
    @ObservationIgnored private let ubiquitous: KeyValueStore

    /// String keys that must stay local-only and never sync through iCloud key-value
    /// storage. AI coaching no longer uses any API key (it runs on Apple's Foundation
    /// Models), so this is currently empty; the machinery is kept for future secrets.
    private static let localOnlyStringKeys: Set<String> = []

    /// Keys whose value is meaningful only on the current device and must never sync
    /// through iCloud KVS. The iCloud-sync toggle itself lives here: syncing it would let
    /// "turn sync off" on one device cascade to every device and disable CloudKit
    /// persistence everywhere (M16).
    private static let deviceLocalKeys: Set<String> = [iCloudSyncKey]

    var unitPreference: UnitPreference {
        didSet {
            persist(unitPreference.rawValue, forKey: Self.unitPreferenceKey)
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
            persist(aiInsightsEnabled, forKey: Self.aiInsightsEnabledKey)
        }
    }

    var aiProvider: AIProvider {
        didSet {
            persist(aiProvider.rawValue, forKey: Self.aiProviderKey)
        }
    }

    var iCloudSyncEnabled: Bool {
        didSet {
            persist(iCloudSyncEnabled, forKey: Self.iCloudSyncKey)
        }
    }

    var morningReminderEnabled: Bool {
        didSet {
            persist(morningReminderEnabled, forKey: Self.morningReminderKey)
        }
    }

    /// The user's weekly running-distance goal, in metres. Drives the weekly
    /// progress ring and consistency badges on the Progress → Achievements tab.
    var weeklyGoalMeters: Double {
        didSet {
            persist(weeklyGoalMeters, forKey: Self.weeklyGoalMetersKey)
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
    static let weeklyGoalMetersKey = "weeklyGoalMeters"

    /// Default weekly goal (20 km) applied when the user has never set one.
    static let defaultWeeklyGoalMeters = 20_000.0

    init(
        defaults: KeyValueStore = UserDefaults.standard,
        ubiquitous: KeyValueStore = NSUbiquitousKeyValueStore.default
    ) {
        self.defaults = defaults
        self.ubiquitous = ubiquitous

        ubiquitous.synchronizeStore()
        Self.removeNonSyncableValues(from: ubiquitous)

        // Snapshot which keys already have a stored value BEFORE writing anything back, so a
        // fresh install does not push in-memory defaults over the user's real values that
        // iCloud KVS has not yet delivered (M15).
        let unitStored = Self.hasStoredValue(forKey: Self.unitPreferenceKey, defaults: defaults, ubiquitous: ubiquitous)
        let aiInsightsStored = Self.hasStoredValue(forKey: Self.aiInsightsEnabledKey, defaults: defaults, ubiquitous: ubiquitous)
        let aiProviderStored = Self.hasStoredValue(forKey: Self.aiProviderKey, defaults: defaults, ubiquitous: ubiquitous)
        let syncStored = Self.hasStoredValue(forKey: Self.iCloudSyncKey, defaults: defaults, ubiquitous: ubiquitous)
        let reminderStored = Self.hasStoredValue(forKey: Self.morningReminderKey, defaults: defaults, ubiquitous: ubiquitous)
        let weeklyGoalStored = Self.hasStoredValue(forKey: Self.weeklyGoalMetersKey, defaults: defaults, ubiquitous: ubiquitous)

        let raw = Self.readString(forKey: Self.unitPreferenceKey, defaults: defaults, ubiquitous: ubiquitous) ?? ""
        self.unitPreference = UnitPreference(rawValue: raw) ?? .metric
        self.orsAPIKey = Self.loadORSAPIKey(defaults: defaults, ubiquitous: ubiquitous)

        self.aiInsightsEnabled = aiInsightsStored
            ? Self.readBool(forKey: Self.aiInsightsEnabledKey, defaults: defaults, ubiquitous: ubiquitous)
            : false

        let providerRaw = Self.readString(forKey: Self.aiProviderKey, defaults: defaults, ubiquitous: ubiquitous) ?? ""
        // New installs default to Apple's on-device model: no API key, private, free.
        self.aiProvider = AIProvider(rawValue: providerRaw) ?? .appleOnDevice

        // Default to true (sync on) when the key has never been set.
        self.iCloudSyncEnabled = syncStored
            ? Self.readBool(forKey: Self.iCloudSyncKey, defaults: defaults, ubiquitous: ubiquitous)
            : true

        // Default to true (reminders on) when the key has never been set.
        self.morningReminderEnabled = reminderStored
            ? Self.readBool(forKey: Self.morningReminderKey, defaults: defaults, ubiquitous: ubiquitous)
            : true

        // Default to 20 km when the user has never set a weekly goal.
        self.weeklyGoalMeters = weeklyGoalStored
            ? (Self.readDouble(forKey: Self.weeklyGoalMetersKey, defaults: defaults, ubiquitous: ubiquitous) ?? Self.defaultWeeklyGoalMeters)
            : Self.defaultWeeklyGoalMeters

        // Write back only the values that already existed somewhere. Seeding a brand-new key
        // into the stores at launch is exactly what clobbers not-yet-synced remote values (M15).
        if unitStored { persist(unitPreference.rawValue, forKey: Self.unitPreferenceKey) }
        if aiInsightsStored { persist(aiInsightsEnabled, forKey: Self.aiInsightsEnabledKey) }
        if aiProviderStored { persist(aiProvider.rawValue, forKey: Self.aiProviderKey) }
        if syncStored { persist(iCloudSyncEnabled, forKey: Self.iCloudSyncKey) }
        if reminderStored { persist(morningReminderEnabled, forKey: Self.morningReminderKey) }
        if weeklyGoalStored { persist(weeklyGoalMeters, forKey: Self.weeklyGoalMetersKey) }
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
    private static func loadORSAPIKey(defaults: KeyValueStore, ubiquitous: KeyValueStore) -> String {
        if let keychainValue = KeychainStore.string(for: orsAPIKeyAccount), !keychainValue.isEmpty {
            // A synced copy may still linger from a pre-migration build on another device.
            purgeLegacyORSAPIKey(defaults: defaults, ubiquitous: ubiquitous)
            return keychainValue
        }

        let legacy = readString(forKey: orsAPIKeyKey, defaults: defaults, ubiquitous: ubiquitous) ?? ""
        if !legacy.isEmpty {
            KeychainStore.set(legacy, for: orsAPIKeyAccount)
        }
        purgeLegacyORSAPIKey(defaults: defaults, ubiquitous: ubiquitous)
        return legacy
    }

    private static func purgeLegacyORSAPIKey(defaults: KeyValueStore, ubiquitous: KeyValueStore) {
        defaults.removeObject(forKey: orsAPIKeyKey)
        ubiquitous.removeObject(forKey: orsAPIKeyKey)
        ubiquitous.synchronizeStore()
    }

    // MARK: - Shared readers

    static func syncedUnitPreference() -> UnitPreference {
        let raw = readString(
            forKey: unitPreferenceKey,
            defaults: UserDefaults.standard,
            ubiquitous: NSUbiquitousKeyValueStore.default
        ) ?? ""
        return UnitPreference(rawValue: raw) ?? .metric
    }

    static func syncedICloudEnabled() -> Bool {
        // The sync toggle is device-local (M16), so this resolves from UserDefaults only.
        let defaults = UserDefaults.standard
        let ubiquitous = NSUbiquitousKeyValueStore.default
        return hasStoredValue(forKey: iCloudSyncKey, defaults: defaults, ubiquitous: ubiquitous)
            ? readBool(forKey: iCloudSyncKey, defaults: defaults, ubiquitous: ubiquitous)
            : true
    }

    // MARK: - Persistence helpers

    private func persist(_ value: String, forKey key: String) {
        Self.persist(value, forKey: key, defaults: defaults, ubiquitous: ubiquitous)
    }

    private func persist(_ value: Bool, forKey key: String) {
        Self.persist(value, forKey: key, defaults: defaults, ubiquitous: ubiquitous)
    }

    private func persist(_ value: Double, forKey key: String) {
        Self.persist(value, forKey: key, defaults: defaults, ubiquitous: ubiquitous)
    }

    private static func persist(_ value: String, forKey key: String, defaults: KeyValueStore, ubiquitous: KeyValueStore) {
        defaults.set(value, forKey: key)

        guard shouldSyncThroughICloud(key) else {
            ubiquitous.removeObject(forKey: key)
            ubiquitous.synchronizeStore()
            return
        }

        ubiquitous.set(value, forKey: key)
        ubiquitous.synchronizeStore()
    }

    private static func persist(_ value: Bool, forKey key: String, defaults: KeyValueStore, ubiquitous: KeyValueStore) {
        defaults.set(value, forKey: key)

        guard shouldSyncThroughICloud(key) else {
            ubiquitous.removeObject(forKey: key)
            ubiquitous.synchronizeStore()
            return
        }

        ubiquitous.set(value, forKey: key)
        ubiquitous.synchronizeStore()
    }

    private static func persist(_ value: Double, forKey key: String, defaults: KeyValueStore, ubiquitous: KeyValueStore) {
        defaults.set(value, forKey: key)

        guard shouldSyncThroughICloud(key) else {
            ubiquitous.removeObject(forKey: key)
            ubiquitous.synchronizeStore()
            return
        }

        ubiquitous.set(value, forKey: key)
        ubiquitous.synchronizeStore()
    }

    /// A key syncs through iCloud unless it is explicitly local-only or device-local.
    private static func shouldSyncThroughICloud(_ key: String) -> Bool {
        !localOnlyStringKeys.contains(key) && !deviceLocalKeys.contains(key)
    }

    private static func removeNonSyncableValues(from ubiquitous: KeyValueStore) {
        var removed = false
        for key in localOnlyStringKeys.union(deviceLocalKeys) where ubiquitous.object(forKey: key) != nil {
            ubiquitous.removeObject(forKey: key)
            removed = true
        }

        if removed {
            ubiquitous.synchronizeStore()
        }
    }

    private static func hasStoredValue(forKey key: String, defaults: KeyValueStore, ubiquitous: KeyValueStore) -> Bool {
        if shouldSyncThroughICloud(key), ubiquitous.object(forKey: key) != nil {
            return true
        }
        return defaults.object(forKey: key) != nil
    }

    private static func readString(forKey key: String, defaults: KeyValueStore, ubiquitous: KeyValueStore) -> String? {
        if shouldSyncThroughICloud(key), let value = ubiquitous.string(forKey: key) {
            return value
        }
        return defaults.string(forKey: key)
    }

    private static func readBool(forKey key: String, defaults: KeyValueStore, ubiquitous: KeyValueStore) -> Bool {
        if shouldSyncThroughICloud(key), ubiquitous.object(forKey: key) != nil {
            return ubiquitous.bool(forKey: key)
        }
        return defaults.bool(forKey: key)
    }

    /// Reads a `Double` via `object(forKey:)` so it works uniformly across
    /// `UserDefaults`, `NSUbiquitousKeyValueStore`, and the in-memory test
    /// double without widening the `KeyValueStore` protocol. Stored `NSNumber`
    /// values bridge to `Double` through the `as?` cast.
    private static func readDouble(forKey key: String, defaults: KeyValueStore, ubiquitous: KeyValueStore) -> Double? {
        if shouldSyncThroughICloud(key), let value = ubiquitous.object(forKey: key) as? Double {
            return value
        }
        return defaults.object(forKey: key) as? Double
    }
}
