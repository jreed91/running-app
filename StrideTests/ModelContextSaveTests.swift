import Foundation
import SwiftData
import Testing
@testable import Stride

/// D5: the app's best-effort saves used to be bare `try?`, so a store that had started
/// rejecting writes was indistinguishable from one that was working. `saveOrLog` keeps
/// the best-effort semantics and adds the trace — these pin the semantics half, since
/// the trace only shows up in the log.
@MainActor
struct ModelContextSaveTests {

    @Test("saveOrLog persists pending changes")
    func saveOrLogWritesChanges() throws {
        let context = TestStore.makeContext()

        let run = RunWorkout(
            date: Date(timeIntervalSince1970: 1_785_024_000),
            distanceMeters: 5_000,
            durationSeconds: 1_500,
            workoutType: .easy
        )
        context.insert(run)

        #expect(context.saveOrLog("a test run"))

        let stored = try context.fetch(FetchDescriptor<RunWorkout>())
        #expect(stored.contains { $0.id == run.id })
    }

    @Test("saveOrLog on a clean context succeeds without writing")
    func saveOrLogOnCleanContextSucceeds() {
        let context = TestStore.makeContext()

        // The `hasChanges` short-circuit must report success, not failure: callers
        // treat `false` as "the store is not consistent with memory".
        #expect(context.saveOrLog("nothing at all"))
        #expect(context.saveOrLog("nothing at all, again"))
    }

    @Test("saveOrLog persists an edit to an already-stored model")
    func saveOrLogWritesEdits() throws {
        let context = TestStore.makeContext()

        let run = RunWorkout(
            date: Date(timeIntervalSince1970: 1_785_024_000),
            distanceMeters: 5_000,
            durationSeconds: 1_500,
            workoutType: .easy
        )
        context.insert(run)
        #expect(context.saveOrLog("a test run"))

        run.workoutType = .tempo
        #expect(context.saveOrLog("the run's type"))
        #expect(context.hasChanges == false)

        let stored = try context.fetch(FetchDescriptor<RunWorkout>())
        #expect(stored.first(where: { $0.id == run.id })?.workoutType == .tempo)
    }
}
