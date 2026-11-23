import Foundation
import Testing
@testable import Stride

/// Covers `WhatsNewPolicy`, `WhatsNewStore` and the `ReleaseNotes` catalog: the sheet
/// opens once per release, never on a fresh install, never backwards, and every release
/// that ships has notes.
@MainActor
struct WhatsNewPolicyTests {

    private final class InMemoryStore: KeyValueStore {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func string(forKey key: String) -> String? { values[key] as? String }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
        func synchronizeStore() {}
    }

    private func release(_ version: String) -> Release {
        Release(
            version: version, releaseDate: nil, headline: "",
            features: [ReleaseFeature(id: "a", title: "A", body: "", icon: .run)],
            improvements: [], fixes: []
        )
    }

    private var catalog: [Release] { [release("1.2"), release("1.1")] }

    // MARK: Keys

    @Test func keysAreMajorDotMinor() {
        #expect(Release.key(forMarketingVersion: "1.2") == "1.2")
        #expect(Release.key(forMarketingVersion: "1.2.1") == "1.2")
        #expect(Release.key(forMarketingVersion: "2") == "2.0")
        #expect(Release.key(forMarketingVersion: "beta") == "beta")
    }

    @Test func versionsCompareAsNumbers() {
        #expect(Release.isNewer("1.10", than: "1.9"))
        #expect(!Release.isNewer("1.9", than: "1.10"))
        #expect(!Release.isNewer("1.2", than: "1.2"))
        #expect(Release.isNewer("2.0", than: "1.12"))
    }

    // MARK: Decisions

    @Test func anUpdateShowsTheReleaseOnce() {
        let first = WhatsNewPolicy.decide(
            marketingVersion: "1.2", lastSeen: "1.1", onboardedThisLaunch: false, catalog: catalog
        )
        #expect(first == .show(release("1.2")))
        let again = WhatsNewPolicy.decide(
            marketingVersion: "1.2", lastSeen: "1.2", onboardedThisLaunch: false, catalog: catalog
        )
        #expect(again == .nothing)
    }

    /// Nobody had seen a sheet before this feature shipped, so a runner updating from 1.1
    /// has no record at all — and still gets it.
    @Test func anUpdateFromBeforeTheSheetExistedShowsIt() {
        let decision = WhatsNewPolicy.decide(
            marketingVersion: "1.2", lastSeen: nil, onboardedThisLaunch: false, catalog: catalog
        )
        #expect(decision == .show(release("1.2")))
    }

    @Test func aFreshInstallIsMarkedSeenWithoutShowing() {
        let decision = WhatsNewPolicy.decide(
            marketingVersion: "1.2", lastSeen: nil, onboardedThisLaunch: true, catalog: catalog
        )
        #expect(decision == .markSeen("1.2"))
    }

    @Test func aBugFixBuildDoesNotShowItAgain() {
        let decision = WhatsNewPolicy.decide(
            marketingVersion: "1.2.1", lastSeen: "1.2", onboardedThisLaunch: false, catalog: catalog
        )
        #expect(decision == .nothing)
    }

    @Test func aReleaseWithNoNotesIsMarkedSeen() {
        let decision = WhatsNewPolicy.decide(
            marketingVersion: "1.3", lastSeen: "1.2", onboardedThisLaunch: false, catalog: catalog
        )
        #expect(decision == .markSeen("1.3"))
    }

    @Test func anOlderBuildLeavesTheRecordAlone() {
        let decision = WhatsNewPolicy.decide(
            marketingVersion: "1.1", lastSeen: "1.2", onboardedThisLaunch: false, catalog: catalog
        )
        #expect(decision == .nothing)
    }

    // MARK: Store

    @Test func theStoreRemembersWhatItShowed() {
        let store = WhatsNewStore(store: InMemoryStore())
        #expect(store.lastSeen == nil)
        let shown = store.apply(.show(release("1.2")))
        #expect(shown?.version == "1.2")
        #expect(store.lastSeen == "1.2")
        #expect(store.apply(.markSeen("1.3")) == nil)
        #expect(store.lastSeen == "1.3")
        #expect(store.apply(.nothing) == nil)
        #expect(store.lastSeen == "1.3")
    }

    @Test func resetMakesTheNextLaunchShowItAgain() {
        let store = WhatsNewStore(store: InMemoryStore())
        store.markSeen("1.2")
        store.reset()
        let decision = WhatsNewPolicy.decide(
            marketingVersion: "1.2", lastSeen: store.lastSeen, onboardedThisLaunch: false, catalog: catalog
        )
        #expect(decision == .show(release("1.2")))
    }

    // MARK: Catalog

    @Test func theCatalogIsNewestFirstWithUniqueVersions() {
        let versions = ReleaseNotes.all.map(\.version)
        #expect(Set(versions).count == versions.count)
        for (newer, older) in zip(versions, versions.dropFirst()) {
            #expect(Release.isNewer(newer, than: older), "\(newer) should come before \(older)")
        }
    }

    @Test func everyReleaseHasFeaturesWithUniqueIDs() {
        for release in ReleaseNotes.all {
            #expect(!release.features.isEmpty, "\(release.version) has no features")
            let ids = release.features.map(\.id)
            #expect(Set(ids).count == ids.count, "\(release.version) repeats a feature id")
            #expect(release.version == Release.key(forMarketingVersion: release.version))
        }
    }

    @Test func screenshotNamesMatchTheWorkflow() {
        let feature = ReleaseNotes.v1point2.features.first { $0.id == "heatmap" }
        #expect(feature?.screenshotName(in: ReleaseNotes.v1point2) == "whatsnew-1.2-heatmap")
        #expect(ReleaseNotes.v1point1.features.allSatisfy { $0.screenshotName(in: ReleaseNotes.v1point1) == nil })
    }

    /// Bump `MARKETING_VERSION` and this fails until the release has notes, so a release
    /// can't ship without its What's New by accident.
    @Test func theRunningVersionHasNotes() throws {
        // Read from the xcconfig itself, beside this file in the checkout (the simulator
        // shares the Mac's file system), so it holds wherever the tests run.
        let xcconfig = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ci_scripts/Version.xcconfig")
        let text = try String(contentsOf: xcconfig, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("MARKETING_VERSION") })
        let version = line.split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        #expect(ReleaseNotes.release(forMarketingVersion: version) != nil,
                "No ReleaseNotes entry for \(version): add one to ReleaseNotes.all")
    }
}
