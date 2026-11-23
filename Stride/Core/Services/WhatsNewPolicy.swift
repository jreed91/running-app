import Foundation

// MARK: - WhatsNewPolicy

/// Decides, once per launch, whether the What's New sheet opens.
///
/// The rules:
/// - Once per release. The release seen is remembered by its `major.minor` key, so a
///   1.2.1 fix doesn't reopen 1.2's sheet, and a TestFlight build after the sheet was seen
///   doesn't either.
/// - Never on a fresh install. Someone who just went through onboarding has not "updated";
///   their release is marked seen without showing it. A reinstall restored from iCloud goes
///   through onboarding's welcome-back screen too, so it counts the same.
/// - Only when the release has notes. A version with no entry in `ReleaseNotes` is marked
///   seen and nothing opens.
/// - Never backwards. A build older than the release already seen (a TestFlight rollback)
///   leaves the record alone.
enum WhatsNewPolicy {

    enum Decision: Equatable {
        /// Open the sheet on this release and remember it as seen.
        case show(Release)
        /// Don't open anything, but remember this release as seen.
        case markSeen(String)
        /// Nothing to do.
        case nothing
    }

    static func decide(
        marketingVersion: String,
        lastSeen: String?,
        onboardedThisLaunch: Bool,
        catalog: [Release] = ReleaseNotes.all
    ) -> Decision {
        let key = Release.key(forMarketingVersion: marketingVersion)
        if let lastSeen, lastSeen == key || Release.isNewer(lastSeen, than: key) {
            return .nothing
        }
        if onboardedThisLaunch {
            return .markSeen(key)
        }
        guard let release = catalog.first(where: { $0.version == key }) else {
            return .markSeen(key)
        }
        return .show(release)
    }
}

// MARK: - WhatsNewStore

/// Where the last release seen is remembered: this device's `UserDefaults`, not iCloud.
/// A runner who updates on two devices sees the sheet on each, which is what they'd
/// expect: each one changed.
@MainActor
struct WhatsNewStore {
    static let lastSeenKey = "whatsNew.lastSeenRelease"

    let store: KeyValueStore

    init(store: KeyValueStore = UserDefaults.standard) {
        self.store = store
    }

    var lastSeen: String? {
        store.string(forKey: Self.lastSeenKey)
    }

    func markSeen(_ key: String) {
        store.set(key, forKey: Self.lastSeenKey)
    }

    /// Forgets the release seen, so the sheet opens again on the next launch. The
    /// TestFlight card's "Show on next launch" calls this.
    func reset() {
        store.removeObject(forKey: Self.lastSeenKey)
    }

    /// Applies `decision` and returns the release to show, if any.
    func apply(_ decision: WhatsNewPolicy.Decision) -> Release? {
        switch decision {
        case .show(let release):
            markSeen(release.version)
            return release
        case .markSeen(let key):
            markSeen(key)
            return nil
        case .nothing:
            return nil
        }
    }

    /// The running app's `CFBundleShortVersionString`.
    static var currentMarketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
