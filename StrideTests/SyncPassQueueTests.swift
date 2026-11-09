import Testing
@testable import Stride

// MARK: - SyncPassQueue tests
//
// The HealthKit import's "one pass at a time, never drop a trigger" rule (M1), on its
// own. `WorkoutSyncServiceTests.observerTriggerQueuedDuringSync` covers it end to end.

struct SyncPassQueueTests {

    private typealias Request = SyncPassQueue.Request

    @Test("The first trigger runs at once")
    func firstTriggerRuns() {
        var queue = SyncPassQueue.idle
        let runsNow = queue.request(Request(source: "startup"))
        #expect(runsNow)
        #expect(queue == .syncing(queued: nil))
        #expect(queue.queuedSource == nil)
    }

    @Test("A trigger mid-pass is queued, not run and not dropped")
    func midPassTriggerQueues() {
        var queue = SyncPassQueue.idle
        _ = queue.request(Request(source: "startup"))
        let runsNow = queue.request(Request(source: "observer"))
        #expect(!runsNow)
        #expect(queue.queuedSource == "observer")
    }

    @Test("Only one follow-up is owed, named by the latest trigger")
    func latestTriggerWins() {
        var queue = SyncPassQueue.idle
        _ = queue.request(Request(source: "startup"))
        _ = queue.request(Request(source: "observer"))
        _ = queue.request(Request(source: "manual"))
        #expect(queue == .syncing(queued: Request(source: "manual")))
    }

    @Test("A queued History pull keeps its 60-day window")
    func queuedWindowIsKept() {
        var queue = SyncPassQueue.idle
        _ = queue.request(Request(source: "startup"))
        _ = queue.request(Request(source: "history", lookbackDays: 60))
        let followUp = queue.next()
        #expect(followUp == Request(source: "history", lookbackDays: 60))
    }

    @Test("Folding triggers keeps the widest window any of them asked for")
    func widestWindowWins() {
        var queue = SyncPassQueue.idle
        _ = queue.request(Request(source: "startup"))
        _ = queue.request(Request(source: "history", lookbackDays: 60))
        _ = queue.request(Request(source: "observer"))
        _ = queue.request(Request(source: "manual", lookbackDays: 30))
        #expect(queue.queued == Request(source: "manual", lookbackDays: 60))
    }

    @Test("Finishing with a follow-up owed hands it back and stays busy")
    func nextRunsFollowUp() {
        var queue = SyncPassQueue.idle
        _ = queue.request(Request(source: "startup"))
        _ = queue.request(Request(source: "observer"))
        let followUp = queue.next()
        #expect(followUp?.source == "observer")
        #expect(queue == .syncing(queued: nil))
        // A trigger during the follow-up is queued too.
        let runsNow = queue.request(Request(source: "observer"))
        #expect(!runsNow)
    }

    @Test("Finishing with nothing owed goes idle, and the next trigger runs")
    func nextGoesIdle() {
        var queue = SyncPassQueue.idle
        _ = queue.request(Request(source: "startup"))
        let followUp = queue.next()
        #expect(followUp == nil)
        #expect(queue == .idle)
        let runsNow = queue.request(Request(source: "observer"))
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
