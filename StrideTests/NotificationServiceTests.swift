import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers NotificationService behaviours that touch persisted state.
@MainActor
struct NotificationServiceTests {

    /// M39: the TestFlight "synced run" QA notification must not write a fake run into
    /// the real store (it previously inserted an unmarked 5 km run that polluted stats
    /// and synced to CloudKit). The tap-to-review flow now rides on the review snapshot.
    @Test("QA synced-run test notification never inserts a run into the store")
    func qaSyncedRunDoesNotPolluteStore() async throws {
        let container = AppContainer.preview()
        let context = container.modelContainer.mainContext

        let before = try context.fetch(FetchDescriptor<RunWorkout>()).count
        try await NotificationService.shared.triggerSyncedRunTestNotification(in: context)
        let after = try context.fetch(FetchDescriptor<RunWorkout>()).count

        #expect(before == 0)
        #expect(after == 0)
    }
}
