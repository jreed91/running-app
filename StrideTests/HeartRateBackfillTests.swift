import Foundation
import Testing
@testable import Stride

/// Covers the selection rule behind the Progress tab's heart-rate backfill (N25):
/// which already-imported runs are worth asking HealthKit about, and how many.
@MainActor
struct HeartRateBackfillTests {

    private func makeRun(
        daysAgo: Double,
        hkID: String?,
        samples: [Double] = []
    ) -> RunWorkout {
        let run = RunWorkout(
            date: Date().addingTimeInterval(-daysAgo * 86_400),
            distanceMeters: 5_000,
            durationSeconds: 1_500
        )
        run.healthKitWorkoutID = hkID
        if !samples.isEmpty { run.heartRateSamples = samples }
        return run
    }

    @Test("Only runs with a HealthKit source and no persisted samples are candidates")
    func selectsOnlyRunsThatCanGainSamples() {
        let needsFetch = makeRun(daysAgo: 1, hkID: "hk-1")
        let alreadyHasSamples = makeRun(daysAgo: 2, hkID: "hk-2", samples: [140, 150])
        let appRecorded = makeRun(daysAgo: 3, hkID: nil)

        let candidates = HeartRateBackfill.runsNeedingSamples(
            in: [needsFetch, alreadyHasSamples, appRecorded]
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.healthKitWorkoutID == "hk-1")
    }

    @Test("Candidates are newest first and capped")
    func newestFirstAndBounded() {
        let runs = (0..<10).map { makeRun(daysAgo: Double($0), hkID: "hk-\($0)") }

        let candidates = HeartRateBackfill.runsNeedingSamples(in: runs.shuffled(), limit: 3)

        #expect(candidates.count == 3)
        #expect(candidates.map(\.healthKitWorkoutID) == ["hk-0", "hk-1", "hk-2"])
    }

    /// A run whose HealthKit workout has been deleted returns no samples forever, so it
    /// must not be re-queried on every period change.
    @Test("Runs already attempted this session are skipped")
    func attemptedRunsAreNotRetried() {
        let runs = [makeRun(daysAgo: 1, hkID: "hk-1"), makeRun(daysAgo: 2, hkID: "hk-2")]

        let candidates = HeartRateBackfill.runsNeedingSamples(
            in: runs,
            alreadyAttempted: ["hk-1"]
        )

        #expect(candidates.map(\.healthKitWorkoutID) == ["hk-2"])
    }

    @Test("A non-positive limit selects nothing")
    func zeroLimitSelectsNothing() {
        let runs = [makeRun(daysAgo: 1, hkID: "hk-1")]
        #expect(HeartRateBackfill.runsNeedingSamples(in: runs, limit: 0).isEmpty)
    }
}
