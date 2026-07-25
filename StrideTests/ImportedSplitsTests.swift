import Testing
import Foundation
@testable import Stride

// MARK: - Splits for imported runs (N9)
//
// Imported runs arrived with no splits at all, so an Apple Watch user — whose runs
// all arrive by import — never saw the split charts, the splits table, or split bars
// on the share card, and interval effort fell back to the session average.

struct ImportedSplitsTests {

    private let km = UnitPreference.metric.splitLengthMeters
    private let mile = UnitPreference.imperial.splitLengthMeters

    /// A steady run sampled once every `interval` seconds at `paceSecondsPerKm`.
    private func steadySeries(
        totalMeters: Double,
        paceSecondsPerKm: Double,
        sampleSeconds: Double = 10
    ) -> [SplitBucketing.DistancePoint] {
        let metersPerSecond = 1_000 / paceSecondsPerKm
        var points: [SplitBucketing.DistancePoint] = []
        var elapsed = sampleSeconds
        while true {
            let meters = min(totalMeters, elapsed * metersPerSecond)
            points.append(.init(elapsedSeconds: elapsed, cumulativeMeters: meters))
            if meters >= totalMeters { break }
            elapsed += sampleSeconds
        }
        return points
    }

    @Test("A steady 5 km run produces five splits at the run's pace")
    func steadyRunBuckets() {
        let splits = SplitBucketing.splits(
            from: steadySeries(totalMeters: 5_000, paceSecondsPerKm: 300),
            splitLengthMeters: km
        )

        #expect(splits.count == 5)
        #expect(splits.map(\.kilometer) == [1, 2, 3, 4, 5])
        #expect(splits.allSatisfy { abs($0.paceSecondsPerKm - 300) < 1 })
        #expect(splits.last?.cumulativeDistanceMeters == 5_000)
    }

    @Test("The same run buckets into miles for an imperial runner")
    func imperialBuckets() {
        let splits = SplitBucketing.splits(
            from: steadySeries(totalMeters: 5_000, paceSecondsPerKm: 300),
            splitLengthMeters: mile
        )

        // 5 km ≈ 3.11 mi → three complete mile buckets.
        #expect(splits.count == 3)
        #expect(splits.allSatisfy { abs($0.paceSecondsPerKm - 300) < 1 })
    }

    @Test("Each split reports its own pace, so a negative split is visible")
    func varyingPacesPerSplit() {
        // km 1 in 330 s, km 2 in 300 s, km 3 in 270 s, sampled only at the boundaries.
        let splits = SplitBucketing.splits(
            from: [
                .init(elapsedSeconds: 330, cumulativeMeters: 1_000),
                .init(elapsedSeconds: 630, cumulativeMeters: 2_000),
                .init(elapsedSeconds: 900, cumulativeMeters: 3_000)
            ],
            splitLengthMeters: km
        )

        #expect(splits.count == 3)
        #expect(zip(splits.map(\.paceSecondsPerKm), [330.0, 300.0, 270.0])
            .allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test("A boundary inside a sample is interpolated, not charged to the sample's end")
    func boundaryInterpolation() {
        // One 20-second sample spans 900 m → 1 100 m at a constant 10 m/s.
        let splits = SplitBucketing.splits(
            from: [
                .init(elapsedSeconds: 90, cumulativeMeters: 900),
                .init(elapsedSeconds: 110, cumulativeMeters: 1_100)
            ],
            splitLengthMeters: km
        )

        #expect(splits.count == 1)
        // The kilometre completed at 100 s, not at the sample's end at 110 s.
        #expect(abs((splits.first?.paceSecondsPerKm ?? 0) - 100) < 0.001)
    }

    @Test("A sample that spans several buckets yields one split per bucket")
    func multipleBucketsInOneSample() {
        let splits = SplitBucketing.splits(
            from: [.init(elapsedSeconds: 900, cumulativeMeters: 3_000)],
            splitLengthMeters: km
        )

        #expect(splits.map(\.kilometer) == [1, 2, 3])
        #expect(splits.allSatisfy { abs($0.paceSecondsPerKm - 300) < 0.001 })
        #expect(splits.map(\.cumulativeDistanceMeters) == [1_000, 2_000, 3_000])
    }

    @Test("A run shorter than one bucket produces no splits")
    func shortRunProducesNothing() {
        #expect(
            SplitBucketing.splits(
                from: steadySeries(totalMeters: 800, paceSecondsPerKm: 300),
                splitLengthMeters: km
            ).isEmpty
        )
        #expect(SplitBucketing.splits(from: [], splitLengthMeters: km).isEmpty)
    }

    @Test("Degenerate input never crashes or emits a bogus pace")
    func degenerateInput() {
        #expect(SplitBucketing.splits(
            from: steadySeries(totalMeters: 3_000, paceSecondsPerKm: 300),
            splitLengthMeters: 0
        ).isEmpty)

        // Out of order, duplicated, backwards, and non-finite readings all survive
        // sanitising, and no split is ever stored with a zero or infinite pace.
        let messy: [SplitBucketing.DistancePoint] = [
            .init(elapsedSeconds: 600, cumulativeMeters: 2_000),
            .init(elapsedSeconds: 300, cumulativeMeters: 1_000),
            .init(elapsedSeconds: 300, cumulativeMeters: 1_000),
            .init(elapsedSeconds: 450, cumulativeMeters: 1_400),
            .init(elapsedSeconds: 500, cumulativeMeters: 900),      // dips backwards
            .init(elapsedSeconds: .nan, cumulativeMeters: 2_500),
            .init(elapsedSeconds: 700, cumulativeMeters: .infinity)
        ]
        let splits = SplitBucketing.splits(from: messy, splitLengthMeters: km)
        #expect(splits.map(\.kilometer) == [1, 2])
        #expect(splits.allSatisfy { $0.paceSecondsPerKm > 0 && $0.paceSecondsPerKm.isFinite })
    }

    @Test("Splits carry a heart rate when the workout has a series")
    func heartRatePerSplit() {
        // 200 samples over 600 s: 120 bpm for the first km, 160 for the second.
        let samples = Array(repeating: 120.0, count: 100) + Array(repeating: 160.0, count: 100)
        let splits = SplitBucketing.splits(
            from: [
                .init(elapsedSeconds: 300, cumulativeMeters: 1_000),
                .init(elapsedSeconds: 600, cumulativeMeters: 2_000)
            ],
            splitLengthMeters: km,
            heartRateSamples: samples,
            totalDurationSeconds: 600
        )

        #expect(splits.count == 2)
        #expect(splits.first?.heartRate == 120)
        #expect(splits.last?.heartRate == 160)
    }

    @Test("Splits have no heart rate when the workout has no series")
    func noHeartRateSeries() {
        let splits = SplitBucketing.splits(
            from: steadySeries(totalMeters: 2_000, paceSecondsPerKm: 300),
            splitLengthMeters: km
        )

        #expect(splits.allSatisfy { $0.heartRate == nil })
    }

    @Test("The heart-rate window is clamped to the series")
    func heartRateWindowClamping() {
        let samples = [100.0, 110.0, 120.0, 130.0]
        #expect(SplitBucketing.averageHeartRate(samples: samples, fromSeconds: 0, toSeconds: 100, totalSeconds: 100) == 115)
        // A window past the end of the workout still reads the final samples.
        #expect(SplitBucketing.averageHeartRate(samples: samples, fromSeconds: 95, toSeconds: 500, totalSeconds: 100) == 130)
        // Empty or degenerate windows have no answer rather than a wrong one.
        #expect(SplitBucketing.averageHeartRate(samples: [], fromSeconds: 0, toSeconds: 10, totalSeconds: 100) == nil)
        #expect(SplitBucketing.averageHeartRate(samples: samples, fromSeconds: 10, toSeconds: 10, totalSeconds: 100) == nil)
        #expect(SplitBucketing.averageHeartRate(samples: samples, fromSeconds: 0, toSeconds: 10, totalSeconds: 0) == nil)
    }
}
