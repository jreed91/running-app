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

    /// Whether each completed kilometre/mile is announced out loud during a run (U4).
    ///
    /// Opt-in, and deliberately so: this is the one setting in the app that makes the
    /// phone talk over whatever the runner is already listening to, and a feature that
    /// starts speaking unasked on the first run after an update is a surprise rather
    /// than a coach.
    var spokenSplitsEnabled: Bool {
        didSet {
            persist(spokenSplitsEnabled, forKey: Self.spokenSplitsKey)
        }
    }

    /// Whether Stride checks tomorrow's forecast and offers to adapt a session that falls
    /// in the heat.
    ///
    /// On by default. It costs one WeatherKit call a day, it only ever speaks up when the
    /// conditions clear a published threshold, and the runner it exists for — the one who
    /// would otherwise set off into a 30 °C tempo with a pace band that stopped being
    /// achievable — is not the runner who goes looking through Settings for a feature they
    /// have never heard of. Off leaves the plan exactly as generated and sends nothing.
    var heatAdaptationEnabled: Bool {
        didSet {
            persist(heatAdaptationEnabled, forKey: Self.heatAdaptationKey)
        }
    }

    /// Whether walking workouts recorded in Apple Health are imported alongside runs (N38).
    ///
    /// On by default: a walking *workout* is one somebody deliberately started, so there
    /// are few of them and each is a session the runner meant to record — recovery days,
    /// the walk half of a run/walk, the weeks around an injury. Off is for the runner who
    /// wants the log to be running and nothing else; turning it off stops future imports
    /// and leaves the walks already imported in place, since deleting a runner's history
    /// behind a toggle is not a thing a settings switch should do.
    var walkImportEnabled: Bool {
        didSet {
            persist(walkImportEnabled, forKey: Self.walkImportKey)
        }
    }

    /// Per-tier run-playlist sources: an Apple Music **library playlist ID** the runner
    /// chose to fill one energy tier from, or empty to use `MusicEnergyPolicy`'s genre table.
    ///
    /// Three flat strings rather than a dictionary because `persist` deals in the three
    /// primitive types the `KeyValueStore` protocol carries, and widening that protocol to
    /// store a codable map for one feature is the wrong trade. Read them through
    /// ``playlistSources`` rather than individually.
    ///
    /// These sync through iCloud KVS like every other non-device-local setting: an Apple
    /// Music library playlist has the same ID on every device the runner signs into, so the
    /// choice is meaningful on all of them. (The *link* from a session to its generated
    /// playlist is a different thing and deliberately does not sync — see `RunPlaylistStore`.)
    var calmPlaylistSourceID: String {
        didSet { persist(calmPlaylistSourceID, forKey: Self.calmPlaylistSourceKey) }
    }

    var steadyPlaylistSourceID: String {
        didSet { persist(steadyPlaylistSourceID, forKey: Self.steadyPlaylistSourceKey) }
    }

    var hardPlaylistSourceID: String {
        didSet { persist(hardPlaylistSourceID, forKey: Self.hardPlaylistSourceKey) }
    }

    /// The runner's per-tier overrides, in the shape `RunPlaylistService` takes.
    /// Tiers left on the genre-table default are omitted rather than sent as empty strings.
    var playlistSources: [RunPlaylistEnergy: String] {
        var sources: [RunPlaylistEnergy: String] = [:]
        for energy in RunPlaylistEnergy.allCases {
            let id = playlistSourceID(for: energy)
            if !id.isEmpty { sources[energy] = id }
        }
        return sources
    }

    func playlistSourceID(for energy: RunPlaylistEnergy) -> String {
        switch energy {
        case .calm:   return calmPlaylistSourceID
        case .steady: return steadyPlaylistSourceID
        case .hard:   return hardPlaylistSourceID
        }
    }

    func setPlaylistSourceID(_ id: String, for energy: RunPlaylistEnergy) {
        switch energy {
        case .calm:   calmPlaylistSourceID = id
        case .steady: steadyPlaylistSourceID = id
        case .hard:   hardPlaylistSourceID = id
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
    static let spokenSplitsKey = "spokenSplitsEnabled"
    static let weeklyGoalMetersKey = "weeklyGoalMeters"
    /// Internal so `WorkoutSyncService` can read the same key without an `AppSettings`,
    /// the way the unit preference is read during a background sync.
    static let walkImportKey = "walkImportEnabled"
    /// Internal so `HeatAdvisoryService`'s callers can gate on the same key.
    static let heatAdaptationKey = "heatAdaptationEnabled"
    private static let calmPlaylistSourceKey   = "runPlaylistSource.calm"
    private static let steadyPlaylistSourceKey = "runPlaylistSource.steady"
    private static let hardPlaylistSourceKey   = "runPlaylistSource.hard"

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
        let spokenSplitsStored = Self.hasStoredValue(forKey: Self.spokenSplitsKey, defaults: defaults, ubiquitous: ubiquitous)
        let weeklyGoalStored = Self.hasStoredValue(forKey: Self.weeklyGoalMetersKey, defaults: defaults, ubiquitous: ubiquitous)
        let walkImportStored = Self.hasStoredValue(forKey: Self.walkImportKey, defaults: defaults, ubiquitous: ubiquitous)
        let heatAdaptationStored = Self.hasStoredValue(forKey: Self.heatAdaptationKey, defaults: defaults, ubiquitous: ubiquitous)
        let calmSourceStored = Self.hasStoredValue(forKey: Self.calmPlaylistSourceKey, defaults: defaults, ubiquitous: ubiquitous)
        let steadySourceStored = Self.hasStoredValue(forKey: Self.steadyPlaylistSourceKey, defaults: defaults, ubiquitous: ubiquitous)
        let hardSourceStored = Self.hasStoredValue(forKey: Self.hardPlaylistSourceKey, defaults: defaults, ubiquitous: ubiquitous)

        let raw = Self.readString(forKey: Self.unitPreferenceKey, defaults: defaults, ubiquitous: ubiquitous) ?? ""
        // No stored choice falls back to what the device already measures in, not to
        // metric: the old default was wrong for every runner in the US who skipped the
        // units step (U10). Still not seeded — an in-memory default only (M15).
        self.unitPreference = UnitPreference(rawValue: raw) ?? .localeDefault
        self.orsAPIKey = Self.loadORSAPIKey(defaults: defaults, ubiquitous: ubiquitous)

        self.aiInsightsEnabled = aiInsightsStored
            ? Self.readBool(forKey: Self.aiInsightsEnabledKey, defaults: defaults, ubiquitous: ubiquitous)
            : false

        let providerRaw = Self.readString(forKey: Self.aiProviderKey, defaults: defaults, ubiquitous: ubiquitous) ?? ""
        // Default to Apple's Private Cloud Compute model: still keyless, still free, still
        // private, but with 32K of context and stronger reasoning than the on-device model
        // — which matters for the coach, whose prompts carry weeks of run history.
        //
        // Safe as a default because it degrades rather than fails. PCC needs an eligible
        // device, the entitlement and a network connection, and when any of those is
        // missing `FoundationModelsCoachBackend` silently runs the request on-device.
        // A runner who explicitly picked on-device keeps that choice — this only applies
        // when the key has never been written.
        self.aiProvider = AIProvider(rawValue: providerRaw) ?? .applePrivateCloud

        // Default to true (sync on) when the key has never been set.
        self.iCloudSyncEnabled = syncStored
            ? Self.readBool(forKey: Self.iCloudSyncKey, defaults: defaults, ubiquitous: ubiquitous)
            : true

        // Default to true (reminders on) when the key has never been set.
        self.morningReminderEnabled = reminderStored
            ? Self.readBool(forKey: Self.morningReminderKey, defaults: defaults, ubiquitous: ubiquitous)
            : true

        // Default to false (silent) when the key has never been set — see the property.
        self.spokenSplitsEnabled = spokenSplitsStored
            ? Self.readBool(forKey: Self.spokenSplitsKey, defaults: defaults, ubiquitous: ubiquitous)
            : false

        // Default to true (walks imported) when the key has never been set — see the property.
        self.walkImportEnabled = walkImportStored
            ? Self.readBool(forKey: Self.walkImportKey, defaults: defaults, ubiquitous: ubiquitous)
            : true

        // Default to true (heat advisories on) when the key has never been set — see the property.
        self.heatAdaptationEnabled = heatAdaptationStored
            ? Self.readBool(forKey: Self.heatAdaptationKey, defaults: defaults, ubiquitous: ubiquitous)
            : true

        // Empty means "use MusicEnergyPolicy's genre table", which is the default every
        // runner starts on — the feature is meant to work with no setup at all.
        self.calmPlaylistSourceID = Self.readString(forKey: Self.calmPlaylistSourceKey, defaults: defaults, ubiquitous: ubiquitous) ?? ""
        self.steadyPlaylistSourceID = Self.readString(forKey: Self.steadyPlaylistSourceKey, defaults: defaults, ubiquitous: ubiquitous) ?? ""
        self.hardPlaylistSourceID = Self.readString(forKey: Self.hardPlaylistSourceKey, defaults: defaults, ubiquitous: ubiquitous) ?? ""

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
        if spokenSplitsStored { persist(spokenSplitsEnabled, forKey: Self.spokenSplitsKey) }
        if weeklyGoalStored { persist(weeklyGoalMeters, forKey: Self.weeklyGoalMetersKey) }
        if walkImportStored { persist(walkImportEnabled, forKey: Self.walkImportKey) }
        if heatAdaptationStored { persist(heatAdaptationEnabled, forKey: Self.heatAdaptationKey) }
        if calmSourceStored { persist(calmPlaylistSourceID, forKey: Self.calmPlaylistSourceKey) }
        if steadySourceStored { persist(steadyPlaylistSourceID, forKey: Self.steadyPlaylistSourceKey) }
        if hardSourceStored { persist(hardPlaylistSourceID, forKey: Self.hardPlaylistSourceKey) }

        observeExternalChanges()
    }

    // MARK: - External (iCloud KVS) changes

    /// Applies settings that iCloud key-value storage delivers from another device
    /// while this one is already running (M15).
    ///
    /// The launch-time snapshot only reconciles at cold start, so a unit change made
    /// on an iPad used to sit invisible on an iPhone that stayed open — and worse,
    /// the next local write on the iPhone would push the stale value back out.
    private func observeExternalChanges() {
        Task { @MainActor [weak self] in
            // `Notification` is not Sendable, so the element is discarded and every
            // value is re-read from the store instead — the same pattern `AuthService`
            // uses for credential revocation.
            for await _ in NotificationCenter.default.notifications(
                named: NSUbiquitousKeyValueStore.didChangeExternallyNotification
            ) {
                guard let self else { return }
                self.applyExternalValues()
            }
        }
    }

    /// Re-reads every iCloud-synced setting and adopts any that changed remotely.
    ///
    /// Internal so tests can drive it directly with a `KeyValueStore` double, which
    /// cannot post the real system notification.
    func applyExternalValues() {
        // The iCloud-sync toggle is deliberately device-local (M16) and the ORS token
        // lives in the Keychain (S1), so neither participates here.
        if let raw = Self.readString(forKey: Self.unitPreferenceKey, defaults: defaults, ubiquitous: ubiquitous),
           let value = UnitPreference(rawValue: raw),
           value != unitPreference {
            unitPreference = value
        }

        if Self.hasStoredValue(forKey: Self.aiInsightsEnabledKey, defaults: defaults, ubiquitous: ubiquitous) {
            let value = Self.readBool(forKey: Self.aiInsightsEnabledKey, defaults: defaults, ubiquitous: ubiquitous)
            if value != aiInsightsEnabled { aiInsightsEnabled = value }
        }

        if let raw = Self.readString(forKey: Self.aiProviderKey, defaults: defaults, ubiquitous: ubiquitous),
           let value = AIProvider(rawValue: raw),
           value != aiProvider {
            aiProvider = value
        }

        if Self.hasStoredValue(forKey: Self.morningReminderKey, defaults: defaults, ubiquitous: ubiquitous) {
            let value = Self.readBool(forKey: Self.morningReminderKey, defaults: defaults, ubiquitous: ubiquitous)
            if value != morningReminderEnabled { morningReminderEnabled = value }
        }

        if Self.hasStoredValue(forKey: Self.spokenSplitsKey, defaults: defaults, ubiquitous: ubiquitous) {
            let value = Self.readBool(forKey: Self.spokenSplitsKey, defaults: defaults, ubiquitous: ubiquitous)
            if value != spokenSplitsEnabled { spokenSplitsEnabled = value }
        }

        if Self.hasStoredValue(forKey: Self.walkImportKey, defaults: defaults, ubiquitous: ubiquitous) {
            let value = Self.readBool(forKey: Self.walkImportKey, defaults: defaults, ubiquitous: ubiquitous)
            if value != walkImportEnabled { walkImportEnabled = value }
        }

        if Self.hasStoredValue(forKey: Self.heatAdaptationKey, defaults: defaults, ubiquitous: ubiquitous) {
            let value = Self.readBool(forKey: Self.heatAdaptationKey, defaults: defaults, ubiquitous: ubiquitous)
            if value != heatAdaptationEnabled { heatAdaptationEnabled = value }
        }

        if let value = Self.readDouble(forKey: Self.weeklyGoalMetersKey, defaults: defaults, ubiquitous: ubiquitous),
           value != weeklyGoalMeters {
            weeklyGoalMeters = value
        }

        if let value = Self.readString(forKey: Self.calmPlaylistSourceKey, defaults: defaults, ubiquitous: ubiquitous),
           value != calmPlaylistSourceID {
            calmPlaylistSourceID = value
        }

        if let value = Self.readString(forKey: Self.steadyPlaylistSourceKey, defaults: defaults, ubiquitous: ubiquitous),
           value != steadyPlaylistSourceID {
            steadyPlaylistSourceID = value
        }

        if let value = Self.readString(forKey: Self.hardPlaylistSourceKey, defaults: defaults, ubiquitous: ubiquitous),
           value != hardPlaylistSourceID {
            hardPlaylistSourceID = value
        }
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

    /// Whether walking workouts should be imported, read without an `AppSettings`.
    ///
    /// A HealthKit sync can run while the app is in the background, before the observable
    /// settings object exists, so `WorkoutSyncService` resolves the toggle the same way it
    /// resolves the unit preference. Defaults to `true` when the runner has never chosen.
    static func syncedWalkImportEnabled() -> Bool {
        let defaults = UserDefaults.standard
        let ubiquitous = NSUbiquitousKeyValueStore.default
        return hasStoredValue(forKey: walkImportKey, defaults: defaults, ubiquitous: ubiquitous)
            ? readBool(forKey: walkImportKey, defaults: defaults, ubiquitous: ubiquitous)
            : true
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
