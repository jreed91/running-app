import Foundation
import Testing
@testable import Stride

/// The week-long protection the automatic pace refresh gives sessions the runner changed
/// on purpose (P1.1).
struct AdaptedSessionsTests {

    private func freshDefaults(_ suite: String) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("An edit is protected for seven days, then the refresh may re-pace it")
    func protectionLastsAWeek() throws {
        let defaults = try freshDefaults("adapted-sessions-week")
        let id = UUID()
        let editedAt = Date(timeIntervalSince1970: 1_800_000_000)
        AdaptedSessions.record(id, at: editedAt, in: defaults)

        #expect(AdaptedSessions.protectedIDs(now: editedAt, in: defaults) == [id])
        let sixDaysLater = editedAt.addingTimeInterval(6 * 86_400)
        #expect(AdaptedSessions.protectedIDs(now: sixDaysLater, in: defaults) == [id])
        let eightDaysLater = editedAt.addingTimeInterval(8 * 86_400)
        #expect(AdaptedSessions.protectedIDs(now: eightDaysLater, in: defaults).isEmpty)
    }

    @Test("Editing a session again restarts its week, and expired edits are dropped")
    func reEditRestartsAndPrunes() throws {
        let defaults = try freshDefaults("adapted-sessions-prune")
        let old = UUID()
        let session = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        AdaptedSessions.record(old, at: start, in: defaults)
        AdaptedSessions.record(session, at: start, in: defaults)

        let tenDaysLater = start.addingTimeInterval(10 * 86_400)
        AdaptedSessions.record(session, at: tenDaysLater, in: defaults)

        #expect(AdaptedSessions.protectedIDs(now: tenDaysLater, in: defaults) == [session])
        // The expired entry is gone from storage, not just filtered out.
        let stored = defaults.dictionary(forKey: AdaptedSessions.key) ?? [:]
        #expect(stored.keys.sorted() == [session.uuidString])
    }

    @Test("Reset clears every protected edit")
    func removeAllClears() throws {
        let defaults = try freshDefaults("adapted-sessions-reset")
        AdaptedSessions.record(UUID(), in: defaults)
        AdaptedSessions.removeAll(from: defaults)
        #expect(AdaptedSessions.protectedIDs(in: defaults).isEmpty)
    }
}
