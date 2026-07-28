import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers which store opens mirror to CloudKit and which do not.
///
/// This is the executable half of F1 (`docs/CLOUDKIT_ANALYSIS_2026-07-28.md`).
/// `ModelConfiguration`'s `cloudKitDatabase` parameter defaults to `.automatic`,
/// which Apple documents as enabling sync from the first container in the app's
/// entitlements — so every configuration built without naming the option synced,
/// including the one behind a user-facing "iCloud Sync: off" toggle.
///
/// The assertions read `cloudKitContainerIdentifier` back off the built
/// configuration rather than checking `AppContainer.persistenceMode`, which is a
/// label the container assigns itself and which stayed `.localOnly` throughout the
/// entire time the store was in fact syncing. The identifier is what SwiftData acts
/// on, and it is the only part of this that a simulator can check — everything else
/// needs two devices and `docs/CLOUDKIT_VALIDATION.md`.
@MainActor
struct CloudKitConfigurationTests {

    private static let storeURL = URL(fileURLWithPath: "/tmp/StrideCloudKitConfigTests.store")

    private static func configuration(
        inMemory: Bool = false,
        cloudKitEnabled: Bool
    ) -> ModelConfiguration {
        AppContainer.makeConfiguration(
            schema: StrideSchema.make(),
            storeURL: storeURL,
            inMemory: inMemory,
            cloudKitEnabled: cloudKitEnabled
        )
    }

    @Test("Sync on mirrors to the app's own container")
    func syncEnabledTargetsTheStrideContainer() {
        let config = Self.configuration(cloudKitEnabled: true)
        #expect(config.cloudKitContainerIdentifier == StrideSchema.cloudKitContainerID)
    }

    @Test("Sync off does not mirror at all")
    func syncDisabledHasNoCloudKitContainer() {
        let config = Self.configuration(cloudKitEnabled: false)
        // Not merely "a different container" — none. `.automatic` would have resolved
        // `iCloud.com.running.stride` from the entitlements here and synced silently.
        #expect(config.cloudKitContainerIdentifier == nil)
    }

    @Test("An in-memory store never mirrors, whatever the sync preference says")
    func inMemoryNeverMirrors() {
        #expect(Self.configuration(inMemory: true, cloudKitEnabled: false).cloudKitContainerIdentifier == nil)
        #expect(Self.configuration(inMemory: true, cloudKitEnabled: true).cloudKitContainerIdentifier == nil)
    }

    @Test("The local fallback is a genuinely different configuration from the CloudKit one")
    func fallbackDiffersFromPrimary() {
        // Tier 1 exists to recover a store-open failure caused by CloudKit. It can only
        // do that if it differs from the configuration that just failed; when both
        // resolved through `.automatic` the retry was the same open twice, and the
        // "falling back to local-only" log line was untrue.
        let primary = Self.configuration(cloudKitEnabled: true)
        let fallback = Self.configuration(cloudKitEnabled: false)
        #expect(primary.cloudKitContainerIdentifier != fallback.cloudKitContainerIdentifier)
    }

    @Test("Both configurations keep the same on-disk store, so no data is orphaned")
    func fallbackSharesTheStoreURL() {
        #expect(Self.configuration(cloudKitEnabled: true).url == Self.storeURL)
        #expect(Self.configuration(cloudKitEnabled: false).url == Self.storeURL)
    }

    @Test("The container identifier matches the one declared in the entitlements")
    func containerIDMatchesEntitlements() {
        // `project.yml` writes this string into
        // `com.apple.developer.icloud-container-identifiers`. A store opened against
        // any other identifier syncs somewhere the app cannot read back.
        #expect(StrideSchema.cloudKitContainerID == "iCloud.com.running.stride")
    }

    @Test("The simulator never mirrors, so a test run cannot write to the real container")
    func simulatorDoesNotSync() {
        // Belt and braces with `inMemoryNeverMirrors`: the unit-test suite builds
        // file-backed containers too (`AppContainerTests`), and those resolve their
        // sync decision through this function. Conditional because the same assertion
        // is false — correctly — when the suite is run on a device.
        #if targetEnvironment(simulator)
        #expect(AppContainer.shouldUseCloudKit(syncEnabled: true, inMemory: false) == false)
        #else
        #expect(AppContainer.shouldUseCloudKit(syncEnabled: true, inMemory: false) == true)
        #endif
    }

    @Test("Sync off and in-memory both refuse CloudKit regardless of environment")
    func explicitOptOutsAreHonoured() {
        #expect(AppContainer.shouldUseCloudKit(syncEnabled: false, inMemory: false) == false)
        #expect(AppContainer.shouldUseCloudKit(syncEnabled: true, inMemory: true) == false)
    }
}
