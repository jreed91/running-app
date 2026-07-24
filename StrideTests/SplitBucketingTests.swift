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
