import Foundation
import Testing
@testable import Stride

/// Covers the rule behind the run-detail split backfill (N9's remaining half): which
/// already-imported runs are worth one HealthKit distance query, and which are not.
@MainActor
struct SplitBackfillTests {

    private func makeRun(
        distanceMeters: Double = 5_000,
        hkID: String? = "hk-1",
        splits: [Split] = []
    ) -> RunWorkout {
        let run = RunWorkout(
            date: Date(),
            distanceMeters: distanceMeters,
            durationSeconds: 1_500
        )
        run.healthKitWorkoutID = hkID
        if !splits.isEmpty { run.splits = splits }
        return run
    }

    private func split(_ km: Int) -> Split {
        Split(
            kilometer: km,
            paceSecondsPerKm: 300,
            heartRate: nil,
            elevationGainMeters: 0,
            cumulativeDistanceMeters: Double(km) * 1_000
        )
    }

    @Test("An imported run with no splits and a whole bucket covered is a candidate")
    func importedRunWithoutSplitsNeedsBackfill() {
        #expect(SplitBackfill.needsSplits(makeRun(), splitLengthMeters: 1_000))
    }

    @Test("A run that already has splits is left alone")
    func runWithSplitsIsSkipped() {
        let run = makeRun(splits: [split(1), split(2)])
        #expect(!SplitBackfill.needsSplits(run, splitLengthMeters: 1_000))
    }

    /// An app-recorded run without splits has no HealthKit distance series to bucket,
    /// so asking would always come back empty.
    @Test("A run with no HealthKit source is skipped")
    func appRecordedRunIsSkipped() {
        let run = makeRun(hkID: nil)
        #expect(!SplitBackfill.needsSplits(run, splitLengthMeters: 1_000))
    }

    /// `SplitBucketing` emits a split only when a boundary is crossed, so a run shorter
    /// than one bucket can never produce one — and a query for it is pure waste.
    @Test("A run shorter than one bucket is skipped")
    func runShorterThanOneBucketIsSkipped() {
        let run = makeRun(distanceMeters: 600)
        #expect(!SplitBackfill.needsSplits(run, splitLengthMeters: 1_000))
    }

    /// The bucket unit is the runner's, so a 1.2 km run is a candidate in metric and
    /// not in imperial — a mile bucket is never completed.
    @Test("Candidacy follows the runner's bucket length")
    func bucketLengthDecidesShortRuns() {
        let run = makeRun(distanceMeters: 1_200)
        #expect(SplitBackfill.needsSplits(run, splitLengthMeters: UnitPreference.metric.splitLengthMeters))
        #expect(!SplitBackfill.needsSplits(run, splitLengthMeters: UnitPreference.imperial.splitLengthMeters))
    }

    @Test("A non-positive bucket length selects nothing")
    func nonPositiveBucketLengthIsSkipped() {
        #expect(!SplitBackfill.needsSplits(makeRun(), splitLengthMeters: 0))
    }
}
