import Foundation
import Testing
@testable import Stride

// MARK: - Widget snapshot store tests
//
// The App Group file is the only channel between the app and the widget extension, and
// every failure path along it is deliberately silent (a `try!` in a Home Screen extension
// is a crash in the one process nobody can read a log from). Silent failure is only safe
// if the round trip is actually tested, which is what this is for. The directory is
// injectable so these run against a temporary directory rather than a real entitled
// container — the entitlement is not available to the test host.

struct WidgetSnapshotStoreTests {

    private func makeStore() throws -> (WidgetSnapshotStore, URL) {
        let directory = URL.temporaryDirectory.appending(path: "widget-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (WidgetSnapshotStore(directory: directory), directory)
    }

    @Test("A snapshot survives the round trip unchanged")
    func roundTripPreservesEveryField() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let written = WidgetSnapshot.sample(now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(store.save(written))
        #expect(store.load() == written)
    }

    @Test("Reading before anything was written yields nil, not a crash")
    func loadWithoutAWriteIsNil() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.load() == nil)
    }

    @Test("A second write replaces the first")
    func writeReplaces() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.save(WidgetSnapshot.sample(now: Date(timeIntervalSince1970: 1_800_000_000)))
        let second = WidgetSnapshot.empty(generatedAt: Date(timeIntervalSince1970: 1_800_090_000))
        store.save(second)

        #expect(store.load() == second)
    }

    @Test("Clearing removes the snapshot so widgets stop showing deleted data")
    func clearRemovesTheFile() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.save(WidgetSnapshot.sample())
        store.clear()

        #expect(store.load() == nil)
    }

    /// The case where the App Group is missing entirely — the entitlement is not granted,
    /// or the identifier was never registered. Both sides have to survive it: the app
    /// skips the write, the widget falls back to its empty state.
    @Test("With no container the store fails quietly instead of trapping")
    func missingContainerIsSurvivable() {
        let store = WidgetSnapshotStore(directory: nil)

        #expect(store.fileURL == nil)
        #expect(store.save(WidgetSnapshot.sample()) == false)
        #expect(store.load() == nil)
        store.clear()   // must not trap
    }

    /// A widget reads whatever is on disk. Corruption — a truncated write, a payload from
    /// a build that has since changed the format — must read as "nothing yet", which is a
    /// card that says to open the app, rather than as a decode crash on the Home Screen.
    @Test("A corrupt file reads as nothing rather than throwing")
    func corruptFileIsTreatedAsAbsent() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = try #require(store.fileURL)
        try Data("not json".utf8).write(to: fileURL)

        #expect(store.load() == nil)
    }

    @Test("The sample and empty snapshots are self-consistent")
    func canonicalSnapshotsAreCoherent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let empty = WidgetSnapshot.empty(generatedAt: now)
        #expect(empty.nextWorkout == nil)
        #expect(empty.race == nil)
        #expect(empty.weekly.hasGoal == false)
        #expect(empty.isStale(asOf: now) == false)

        // The gallery renders every widget before the user picks one, so the sample has
        // to fill every section — an empty card there is a widget nobody adds.
        let sample = WidgetSnapshot.sample(now: now)
        #expect(sample.nextWorkout != nil)
        #expect(sample.race?.isUpcoming(asOf: now) == true)
        #expect(sample.weekly.hasGoal)
        #expect(sample.streak.current > 0)
    }
}
