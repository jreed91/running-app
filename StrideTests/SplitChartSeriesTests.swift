import Foundation
import Testing
@testable import Stride

/// Covers `SplitChartSeries`, the rule behind what the run summary's split charts plot (N34).
///
/// A `Split` closes on a whole kilometre or mile, so a one-mile run had exactly one of them
/// and its pace and heart-rate charts drew a single marker. The charts re-bucket a short
/// run's recorded distance readings into fractions of the unit instead; the table keeps the
/// whole-unit rows.
struct SplitChartSeriesTests {

    private let mile = UnitPreference.imperial.splitLengthMeters
    private let km = UnitPreference.metric.splitLengthMeters

    /// A steady run of `distanceMeters` at `paceSecondsPerKm`, sampled every 10 m the way
    /// the tracker banks readings.
    private func series(
        distanceMeters: Double,
        paceSecondsPerKm: Double = 300,
        altitudeStepMeters: Double? = nil
    ) -> [SplitBucketing.DistancePoint] {
        var points: [SplitBucketing.DistancePoint] = []
        var covered: Double = 0
        var altitude: Double = altitudeStepMeters == nil ? 0 : 100
        while covered < distanceMeters {
            covered = min(covered + 10, distanceMeters)
            if let step = altitudeStepMeters { altitude += step }
            points.append(
                SplitBucketing.DistancePoint(
                    elapsedSeconds: covered / 1_000 * paceSecondsPerKm,
                    cumulativeMeters: covered,
                    altitudeMeters: altitudeStepMeters == nil ? nil : altitude
                )
            )
        }
        return points
    }

    private func run(
        distanceMeters: Double,
        paceSecondsPerKm: Double = 300,
        unit: UnitPreference = .imperial,
        withSeries: Bool = true,
        altitudeStepMeters: Double? = nil,
        heartRateSamples: [Double] = []
    ) -> RunWorkout {
        let duration = distanceMeters / 1_000 * paceSecondsPerKm
        let workout = RunWorkout(distanceMeters: distanceMeters, durationSeconds: duration)
        workout.splitUnit = unit
        workout.splits = SplitBucketing.splits(
            from: series(distanceMeters: distanceMeters, paceSecondsPerKm: paceSecondsPerKm),
            splitLengthMeters: unit.splitLengthMeters
        )
        if withSeries {
            workout.distanceSeries = series(
                distanceMeters: distanceMeters,
                paceSecondsPerKm: paceSecondsPerKm,
                altitudeStepMeters: altitudeStepMeters
            )
        }
        if !heartRateSamples.isEmpty { workout.heartRateSamples = heartRateSamples }
        return workout
    }

    // MARK: Resolution ladder

    @Test("A one-mile run is charted on tenths rather than as a single bar")
    func oneMileSubdividesToTenths() {
        let fraction = SplitChartSeries.bucketFraction(distanceMeters: mile, unitLengthMeters: mile)

        #expect(fraction == 0.1)
    }

    @Test("The ladder takes the coarsest fraction that still makes a chart")
    func ladderPicksCoarsestUsableFraction() {
        // 2 miles: quarters give eight buckets, halves only four.
        #expect(SplitChartSeries.bucketFraction(distanceMeters: 2 * mile, unitLengthMeters: mile) == 0.25)
        // 3 miles: halves give six, which is the floor.
        #expect(SplitChartSeries.bucketFraction(distanceMeters: 3 * mile, unitLengthMeters: mile) == 0.5)
        // 5K in kilometres: halves give ten, whole kilometres only five.
        #expect(SplitChartSeries.bucketFraction(distanceMeters: 5_000, unitLengthMeters: km) == 0.5)
    }

    @Test("A run long enough for whole-unit splits keeps them")
    func longRunKeepsWholeUnits() {
        #expect(SplitChartSeries.bucketFraction(distanceMeters: 6 * mile, unitLengthMeters: mile) == 1)
        #expect(SplitChartSeries.bucketFraction(distanceMeters: 42_195, unitLengthMeters: km) == 1)
    }

    @Test("A run too short for any fraction still gets the finest one")
    func veryShortRunGetsFinestFraction() {
        // 400 m: four tenth-kilometre buckets is short of the floor, and still four more
        // markers than the zero a sub-kilometre run had.
        #expect(SplitChartSeries.bucketFraction(distanceMeters: 400, unitLengthMeters: km) == 0.1)
    }

    @Test("A zero or nonsense distance falls back to whole units rather than dividing by it")
    func degenerateDistanceIsSafe() {
        #expect(SplitChartSeries.bucketFraction(distanceMeters: 0, unitLengthMeters: km) == 1)
        #expect(SplitChartSeries.bucketFraction(distanceMeters: .nan, unitLengthMeters: km) == 1)
        #expect(SplitChartSeries.bucketFraction(distanceMeters: 5_000, unitLengthMeters: 0) == 1)
    }

    // MARK: Bucket labels

    @Test("The bucket label names what a bar covers")
    func bucketLabelNamesTheBar() {
        #expect(SplitChartSeries.bucketLabel(fraction: 1, unit: .imperial) == "mi")
        #expect(SplitChartSeries.bucketLabel(fraction: 0.5, unit: .imperial) == "0.5 mi")
        #expect(SplitChartSeries.bucketLabel(fraction: 0.25, unit: .metric) == "0.25 km")
        #expect(SplitChartSeries.bucketLabel(fraction: 0.1, unit: .imperial) == "0.1 mi")
    }

    @Test("Axis labels name distance covered, in the charted unit")
    func axisLabelsNameDistance() {
        #expect(SplitChartSeries.axisLabel(cumulativeMeters: 3 * mile, unit: .imperial, fraction: 1) == "3")
        #expect(
            SplitChartSeries.axisLabel(cumulativeMeters: 0.4 * mile, unit: .imperial, fraction: 0.1) == "0.4"
        )
        #expect(SplitChartSeries.axisLabel(cumulativeMeters: mile, unit: .imperial, fraction: 0.1) == "1")
        #expect(SplitChartSeries.axisLabel(cumulativeMeters: 2_500, unit: .metric, fraction: 0.5) == "2.5")
    }

    // MARK: Resolving a run

    @Test("A one-mile run charts ten buckets where it stored one split")
    func oneMileRunIsRebucketed() {
        let workout = run(distanceMeters: mile)
        #expect(workout.splits.count == 1)

        let resolved = SplitChartSeries.resolve(for: workout, unit: .imperial)

        #expect(resolved.isSubdivided)
        #expect(resolved.splits.count == 10)
        #expect(resolved.bucketLabel == "0.1 mi")
    }

    @Test("A run under one whole unit charts something instead of nothing")
    func subUnitRunStillCharts() {
        let workout = run(distanceMeters: 0.6 * mile)
        #expect(workout.splits.isEmpty)

        let resolved = SplitChartSeries.resolve(for: workout, unit: .imperial)

        #expect(resolved.splits.count == 6)
    }

    @Test("A long run keeps the whole-unit splits its table shows")
    func longRunUsesStoredSplits() {
        let workout = run(distanceMeters: 10 * mile)

        let resolved = SplitChartSeries.resolve(for: workout, unit: .imperial)

        #expect(!resolved.isSubdivided)
        #expect(resolved.splits == workout.splits)
        #expect(resolved.bucketLabel == "mi")
    }

    @Test("A run recorded before the readings were kept charts its stored splits")
    func runWithoutSeriesFallsBackToStoredSplits() {
        let workout = run(distanceMeters: mile, withSeries: false)

        let resolved = SplitChartSeries.resolve(for: workout, unit: .imperial)

        #expect(!resolved.isSubdivided)
        #expect(resolved.splits == workout.splits)
    }

    @Test("A stored kilometre-bucketed run keeps reading in kilometres when it isn't subdivided")
    func storedSplitsKeepTheirRecordedUnit() {
        let workout = run(distanceMeters: 12_000, unit: .metric, withSeries: false)

        let resolved = SplitChartSeries.resolve(for: workout, unit: .imperial)

        #expect(resolved.unit == .metric)
    }

    @Test("Re-bucketing carries the heart rate the whole-unit split averaged over")
    func rebucketedSplitsCarryHeartRate() {
        // A rising series, so the tenth-mile buckets have to differ from each other for the
        // chart to be worth drawing at all.
        let samples = (0..<100).map { Double(130 + $0 / 2) }
        let workout = run(distanceMeters: mile, heartRateSamples: samples)

        let resolved = SplitChartSeries.resolve(for: workout, unit: .imperial)
        let rates = resolved.splits.compactMap(\.heartRate)

        #expect(rates.count == resolved.splits.count)
        #expect(rates.first ?? 0 < rates.last ?? 0)
    }

    @Test("Re-bucketing carries the climb inside each finer bucket")
    func rebucketedSplitsCarryElevation() {
        // A metre of ascent every 10 m of running: ~161 m over the mile, ~16 per tenth.
        let workout = run(distanceMeters: mile, altitudeStepMeters: 1)

        let resolved = SplitChartSeries.resolve(for: workout, unit: .imperial)

        #expect(resolved.splits.allSatisfy { $0.elevationGainMeters > 10 })
        #expect(SplitChartMetric.available(for: resolved.splits).contains(.elevation))
    }

    @Test("A series too broken to bucket leaves the stored splits alone")
    func unusableSeriesKeepsStoredSplits() {
        let workout = run(distanceMeters: mile)
        workout.distanceSeries = [
            SplitBucketing.DistancePoint(elapsedSeconds: 0, cumulativeMeters: 0),
            SplitBucketing.DistancePoint(elapsedSeconds: 480, cumulativeMeters: 12)
        ]

        let resolved = SplitChartSeries.resolve(for: workout, unit: .imperial)

        #expect(!resolved.isSubdivided)
        #expect(resolved.splits == workout.splits)
    }

    // MARK: Chart selection

    /// Buckets 1…`count`, carrying a heart rate only for the buckets in `withHeartRate`.
    private func selectableSplits(count: Int, withHeartRate: Set<Int>? = nil) -> [Split] {
        (1...count).compactMap { bucket in
            let carriesHeartRate = withHeartRate?.contains(bucket) ?? true
            guard carriesHeartRate else { return nil }
            return Split(
                kilometer: bucket,
                paceSecondsPerKm: 300,
                heartRate: 150,
                elevationGainMeters: 0,
                cumulativeDistanceMeters: Double(bucket) * mile
            )
        }
    }

    @Test("A selection on a plotted bucket resolves to that bucket")
    func selectionOnABucketResolvesToIt() {
        let splits = selectableSplits(count: 5)

        #expect(SplitChartSeries.nearestSplit(to: 3, in: splits)?.kilometer == 3)
        #expect(SplitChartSeries.nearestSplit(to: 1, in: splits)?.kilometer == 1)
        #expect(SplitChartSeries.nearestSplit(to: 5, in: splits)?.kilometer == 5)
    }

    /// The heart-rate chart is drawn only from line and point marks, so its x axis scales
    /// continuously and a selection arrives from between two markers. Matching a bucket
    /// exactly left the chart with a hover that showed nothing at all.
    @Test("A selection between markers resolves to the nearer one")
    func selectionBetweenMarkersResolvesToTheNearest() {
        let splits = selectableSplits(count: 10, withHeartRate: [2, 8])

        #expect(SplitChartSeries.nearestSplit(to: 3, in: splits)?.kilometer == 2)
        #expect(SplitChartSeries.nearestSplit(to: 7, in: splits)?.kilometer == 8)
        // Exactly between the two: one of them wins, and the lower one wins consistently
        // so the tooltip doesn't flicker while a finger sits still.
        #expect(SplitChartSeries.nearestSplit(to: 5, in: splits)?.kilometer == 2)
    }

    @Test("A selection past either end resolves to the end marker")
    func selectionOffTheEndsResolvesToTheEndMarkers() {
        let splits = selectableSplits(count: 4)

        #expect(SplitChartSeries.nearestSplit(to: 0, in: splits)?.kilometer == 1)
        #expect(SplitChartSeries.nearestSplit(to: 99, in: splits)?.kilometer == 4)
    }

    @Test("A chart with nothing plotted resolves no selection")
    func selectionOnAnEmptyChartResolvesToNothing() {
        #expect(SplitChartSeries.nearestSplit(to: 3, in: []) == nil)
    }

    // MARK: Persistence

    @Test("The distance series round-trips through the run's stored JSON")
    func seriesRoundTrips() {
        let workout = RunWorkout(distanceMeters: mile, durationSeconds: 480)
        let points = series(distanceMeters: 100, altitudeStepMeters: 2)
        workout.distanceSeries = points

        #expect(workout.distanceSeries == points)

        // An emptied series clears the column rather than storing "[]", the way the run's
        // other optional JSON payloads behave.
        workout.distanceSeries = []
        #expect(workout.distanceSeriesData == nil)
        #expect(workout.distanceSeries.isEmpty)
    }
}
