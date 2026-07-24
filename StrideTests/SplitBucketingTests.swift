import Testing
import Foundation
@testable import Stride

// MARK: - SplitBucketing / unit-aware splits tests (A1)
//
// Covers record-time bucketing of splits by the user's distance unit so imperial
// runners get genuine per-mile splits instead of kilometre buckets relabelled "mi".

struct SplitBucketingTests {

    private let mile = UnitPreference.imperial.splitLengthMeters   // 1 609.344
    private let km = UnitPreference.metric.splitLengthMeters       // 1 000

    @Test("Unit split lengths are 1 km and 1 mile")
    func splitLengths() {
        #expect(UnitPreference.metric.splitLengthMeters == 1_000)
        #expect(UnitPreference.imperial.splitLengthMeters == 1_609.344)
    }

    @Test("Bucket index counts completed whole buckets")
    func bucketIndexCounts() {
        #expect(SplitBucketing.bucketIndex(distanceMeters: 0, splitLengthMeters: km) == 0)
        #expect(SplitBucketing.bucketIndex(distanceMeters: 999, splitLengthMeters: km) == 0)
        #expect(SplitBucketing.bucketIndex(distanceMeters: 1_000, splitLengthMeters: km) == 1)
        #expect(SplitBucketing.bucketIndex(distanceMeters: 2_400, splitLengthMeters: km) == 2)
        // Same 2 400 m is only the first mile bucket.
        #expect(SplitBucketing.bucketIndex(distanceMeters: 2_400, splitLengthMeters: mile) == 1)
        #expect(SplitBucketing.bucketIndex(distanceMeters: 3_218, splitLengthMeters: mile) == 1)
        #expect(SplitBucketing.bucketIndex(distanceMeters: 3_220, splitLengthMeters: mile) == 2)
    }

    @Test("Degenerate inputs never crash or over-count")
    func degenerateInputs() {
        #expect(SplitBucketing.bucketIndex(distanceMeters: 5_000, splitLengthMeters: 0) == 0)
        #expect(SplitBucketing.bucketIndex(distanceMeters: -10, splitLengthMeters: km) == 0)
    }

    @Test("Crossing a metric boundary records a split; sub-boundary progress does not")
    func metricBoundaryCrossing() {
        #expect(SplitBucketing.crossedBoundary(previousMeters: 950, currentMeters: 1_010, splitLengthMeters: km))
        #expect(!SplitBucketing.crossedBoundary(previousMeters: 1_010, currentMeters: 1_200, splitLengthMeters: km))
    }

    @Test("A 5 km run yields exactly 5 mile buckets vs 3 mile buckets")
    func fullRunBucketCounts() {
        // 5 km → 5 complete km buckets.
        #expect(SplitBucketing.bucketIndex(distanceMeters: 5_000, splitLengthMeters: km) == 5)
        // 5 km ≈ 3.11 mi → 3 complete mile buckets (an imperial 5 km run shows 3 mile splits).
        #expect(SplitBucketing.bucketIndex(distanceMeters: 5_000, splitLengthMeters: mile) == 3)
    }

    @Test("A metric boundary is NOT crossed at the same distance under a mile bucket")
    func unitChangesBoundary() {
        // Passing 1 000 m completes a km split but not a mile split.
        #expect(SplitBucketing.crossedBoundary(previousMeters: 990, currentMeters: 1_010, splitLengthMeters: km))
        #expect(!SplitBucketing.crossedBoundary(previousMeters: 990, currentMeters: 1_010, splitLengthMeters: mile))
    }
}

// MARK: - Split pace (N7)
//
// A split's pace has to be that split's own average — Δtime ÷ Δdistance — not the
// instantaneous GPS speed (outdoor) or the cumulative session average (indoor) that
// happened to be showing when the boundary was crossed.

struct SplitPaceTests {

    @Test("Split pace is the bucket's own average, in seconds per km")
    func paceFromDeltas() {
        // 1 000 m in 5:00 → 300 s/km.
        let kmPace = SplitBucketing.splitPaceSecondsPerKm(deltaSeconds: 300, deltaMeters: 1_000)
        #expect(abs((kmPace ?? 0) - 300) < 0.001)
        // A mile bucket run in 8:00 → 8:00/mi ≈ 298.3 s/km.
        let milePace = SplitBucketing.splitPaceSecondsPerKm(
            deltaSeconds: 480, deltaMeters: UnitPreference.imperial.splitLengthMeters
        )
        #expect(milePace != nil)
        #expect(abs((milePace ?? 0) - 298.26) < 0.1)
    }

    @Test("Consecutive buckets report different paces for a negative-split run")
    func negativeSplitIsVisible() {
        // Cumulative: km 1 in 330 s, km 2 in a further 300 s, km 3 in a further 285 s.
        let boundaries: [(elapsed: Double, meters: Double)] = [
            (330, 1_000), (630, 2_000), (915, 3_000)
        ]
        var previous = (elapsed: 0.0, meters: 0.0)
        var paces: [Double] = []
        for boundary in boundaries {
            let pace = SplitBucketing.splitPaceSecondsPerKm(
                deltaSeconds: boundary.elapsed - previous.elapsed,
                deltaMeters: boundary.meters - previous.meters
            )
            #expect(pace != nil)
            paces.append(pace ?? 0)
            previous = boundary
        }
        #expect(zip(paces, [330.0, 300.0, 285.0]).allSatisfy { abs($0 - $1) < 0.001 })
        // The cumulative average — what the indoor path used to store for every split
        // — would have reported the same rising number three times instead.
        #expect(paces[0] > paces[1] && paces[1] > paces[2])
    }

    @Test("Overshooting the boundary is priced at the distance actually covered")
    func overshootUsesRealDistance() {
        // A fix lands at 1 040 m rather than exactly 1 000 m.
        let pace = SplitBucketing.splitPaceSecondsPerKm(deltaSeconds: 312, deltaMeters: 1_040)
        #expect(abs((pace ?? 0) - 300) < 0.001)
    }

    @Test("Degenerate buckets return nil instead of an infinite or zero pace")
    func degenerateBuckets() {
        #expect(SplitBucketing.splitPaceSecondsPerKm(deltaSeconds: 300, deltaMeters: 0) == nil)
        #expect(SplitBucketing.splitPaceSecondsPerKm(deltaSeconds: 0, deltaMeters: 1_000) == nil)
        #expect(SplitBucketing.splitPaceSecondsPerKm(deltaSeconds: -5, deltaMeters: 1_000) == nil)
        #expect(SplitBucketing.splitPaceSecondsPerKm(deltaSeconds: 300, deltaMeters: -1_000) == nil)
        #expect(SplitBucketing.splitPaceSecondsPerKm(deltaSeconds: .infinity, deltaMeters: 1_000) == nil)
    }
}

// MARK: - RunWorkout split-unit tagging

struct RunWorkoutSplitUnitTests {

    @Test("Legacy runs default to metric split unit")
    func defaultsToMetric() {
        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_500)
        #expect(run.splitUnit == .metric)
        #expect(run.splitUnitRaw == UnitPreference.metric.rawValue)
    }

    @Test("Split unit round-trips through the raw field")
    func splitUnitRoundTrips() {
        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_500)
        run.splitUnit = .imperial
        #expect(run.splitUnitRaw == "imperial")
        #expect(run.splitUnit == .imperial)
    }
}
