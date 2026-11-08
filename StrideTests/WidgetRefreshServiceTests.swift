import Foundation
import Testing
@testable import Stride

// MARK: - Widget refresh without a scene (P2.3)
//
// A Watch run is imported in the background, and the daily app refresh runs with no
// scene either, so neither has the `AppSettings` the scene-phase refresh passes. They
// publish through the overload that takes the two values the snapshot reads. The store
// is pointed at a temporary directory: the App Group entitlement is not available to the
// test host.

@MainActor
struct WidgetRefreshServiceTests {

    @Test("A refresh with no AppSettings writes the snapshot, then reloads only when it moved (P2.3)")
    func refreshWithoutSettingsReloadsOnce() throws {
        let directory = URL.temporaryDirectory.appending(path: "widget-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let context = TestStore.makeContext()
        let now = Date()
        var reloads = 0

        let first = WidgetRefreshService.refresh(
            context: context,
            weeklyGoalMeters: 30_000,
            unit: .imperial,
            now: now,
            store: store,
            reload: { reloads += 1 }
        )
        let again = WidgetRefreshService.refresh(
            context: context,
            weeklyGoalMeters: 30_000,
            unit: .imperial,
            now: now,
            store: store,
            reload: { reloads += 1 }
        )

        let expected = WidgetRefreshService.makeSnapshot(
            context: context,
            weeklyGoalMeters: 30_000,
            unit: .imperial,
            now: now
        )
        #expect(first)
        #expect(!again)
        #expect(reloads == 1)
        #expect(store.load()?.weekly == expected.weekly)
    }
}
