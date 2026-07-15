import Foundation
import SwiftData
import Testing
@testable import Stride

@MainActor
struct AppContainerTests {

    @Test("Preview container uses in-memory persistence")
    func previewUsesInMemoryContainer() {
        let container = AppContainer.preview()
        #expect(container.persistenceMode == .inMemory)
    }

    @Test("Disabling sync boots AppContainer in local-only mode")
    func syncDisabledUsesLocalStore() async throws {
        let storeURL = Self.makeTemporaryStoreURL()
        defer { Self.removeStoreArtifacts(at: storeURL) }

        let container = AppContainer(
            syncEnabledOverride: false,
            storeURLOverride: storeURL
        )

        #expect(container.persistenceMode == .localOnly)

        let workout = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_700)
        try container.workoutRepository.save(workout)
        #expect((try container.workoutRepository.fetchAll()).count == 1)
    }

    @Test("Forced CloudKit failure falls back to local-only store on the same URL")
    func cloudKitFailureFallsBackToLocalStore() throws {
        let storeURL = Self.makeTemporaryStoreURL()
        defer { Self.removeStoreArtifacts(at: storeURL) }

        var invocationCount = 0
        let container = AppContainer(
            syncEnabledOverride: true,
            forceCloudKit: true,
            storeURLOverride: storeURL,
            modelContainerFactory: { schema, configurations in
                invocationCount += 1
                if invocationCount == 1 {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return try ModelContainer(for: schema, configurations: configurations)
            }
        )

        #expect(invocationCount == 2)
        #expect(container.persistenceMode == .localFallback)

        let route = SavedRoute(
            name: "Fallback Route",
            routeType: .loop,
            requestedDistanceMeters: 4_000,
            actualDistanceMeters: 4_100,
            estimatedDurationSeconds: 1_500,
            startLatitude: 41.0,
            startLongitude: -87.0,
            coordinates: [],
            steps: []
        )
        try container.routeRepository.save(route)
        #expect((try container.routeRepository.fetchAll()).count == 1)
    }

    @Test("With CloudKit off, a failing store skips the identical retry and is backed up, not deleted")
    func localOnlyFailureBacksUpStoreBeforeRecreating() throws {
        let storeURL = Self.makeTemporaryStoreURL()
        defer { Self.removeStoreArtifacts(at: storeURL) }

        try Data("not a database".utf8).write(to: storeURL)

        var invocationCount = 0
        let container = AppContainer(
            syncEnabledOverride: false,
            forceCloudKit: false,
            storeURLOverride: storeURL,
            modelContainerFactory: { schema, configurations in
                invocationCount += 1
                if invocationCount == 1 {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return try ModelContainer(for: schema, configurations: configurations)
            }
        )

        // Primary local open, then the tier-2 recreate — no identical tier-1 retry between.
        #expect(invocationCount == 2)
        #expect(container.persistenceMode == .recreatedLocalFallback)

        // The broken store file was moved aside, not deleted.
        let directory = storeURL.deletingLastPathComponent()
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(storeURL.lastPathComponent + ".broken-") }
        #expect(backups.count == 1)
        for name in backups {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    @Test("Repeated persistent-store failures eventually use emergency in-memory mode")
    func repeatedPersistentFailuresUseEmergencyMemory() throws {
        let storeURL = Self.makeTemporaryStoreURL()
        defer { Self.removeStoreArtifacts(at: storeURL) }

        var invocationCount = 0
        let container = AppContainer(
            syncEnabledOverride: true,
            forceCloudKit: true,
            storeURLOverride: storeURL,
            modelContainerFactory: { schema, configurations in
                invocationCount += 1
                if invocationCount < 4 {
                    throw CocoaError(.fileWriteUnknown)
                }
                return try ModelContainer(for: schema, configurations: configurations)
            }
        )

        #expect(invocationCount == 4)
        #expect(container.persistenceMode == .emergencyInMemory)
    }

    private static func makeTemporaryStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("store")
    }

    private static func removeStoreArtifacts(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
