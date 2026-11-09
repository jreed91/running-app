import Testing
@testable import Stride

// MARK: - SyncPassQueue tests
//
// The HealthKit import's "one pass at a time, never drop a trigger" rule (M1), on its
// own. `WorkoutSyncServiceTests.observerTriggerQueuedDuringSync` covers it end to end.

struct SyncPassQueueTests {

    @Test("The first trigger runs at once")
    func firstTriggerRuns() {
        var queue = SyncPassQueue.idle
        let runsNow = queue.request("startup")
        #expect(runsNow)
        #expect(queue == .syncing(queued: nil))
        #expect(queue.queuedSource == nil)
    }

    @Test("A trigger mid-pass is queued, not run and not dropped")
    func midPassTriggerQueues() {
        var queue = SyncPassQueue.idle
        _ = queue.request("startup")
        let runsNow = queue.request("observer")
        #expect(!runsNow)
        #expect(queue.queuedSource == "observer")
    }

    @Test("Only one follow-up is owed, named by the latest trigger")
    func latestTriggerWins() {
        var queue = SyncPassQueue.idle
        _ = queue.request("startup")
        _ = queue.request("observer")
        _ = queue.request("manual")
        #expect(queue == .syncing(queued: "manual"))
    }

    @Test("Finishing with a follow-up owed hands it back and stays busy")
    func nextRunsFollowUp() {
        var queue = SyncPassQueue.idle
        _ = queue.request("startup")
        _ = queue.request("observer")
        let followUp = queue.next()
        #expect(followUp == "observer")
        #expect(queue == .syncing(queued: nil))
        // A trigger during the follow-up is queued too.
        let runsNow = queue.request("observer")
        #expect(!runsNow)
    }

    @Test("Finishing with nothing owed goes idle, and the next trigger runs")
    func nextGoesIdle() {
        var queue = SyncPassQueue.idle
        _ = queue.request("startup")
        let followUp = queue.next()
        #expect(followUp == nil)
        #expect(queue == .idle)
        let runsNow = queue.request("observer")
        #expect(runsNow)
    }

    @Test("next() while idle is a no-op")
    func nextWhenIdle() {
        var queue = SyncPassQueue.idle
        let followUp = queue.next()
        #expect(followUp == nil)
        #expect(queue == .idle)
    }
}
