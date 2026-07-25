import Foundation

/// Pure split-boundary math shared by the outdoor (GPS) and indoor (pedometer) tracking
/// paths so both bucket splits identically. Splits are bucketed by the user's distance unit
/// at record time — one bucket per kilometre or per mile — so imperial runners get genuine
/// per-mile splits rather than kilometre buckets merely relabelled "mi" (A1).
enum SplitBucketing {

    /// The count of whole split buckets completed at a given cumulative distance.
    /// e.g. at 2 400 m with a 1 000 m bucket this is `2`; with a 1 609.344 m (mile) bucket, `1`.
    static func bucketIndex(distanceMeters: Double, splitLengthMeters: Double) -> Int {
        guard splitLengthMeters > 0, distanceMeters > 0 else { return 0 }
        return Int(distanceMeters / splitLengthMeters)
    }

    /// Whether advancing from `previousMeters` to `currentMeters` completes at least one new
    /// bucket, i.e. a split should be recorded for `currentMeters`.
    static func crossedBoundary(
        previousMeters: Double,
        currentMeters: Double,
        splitLengthMeters: Double
    ) -> Bool {
        bucketIndex(distanceMeters: currentMeters, splitLengthMeters: splitLengthMeters)
            > bucketIndex(distanceMeters: previousMeters, splitLengthMeters: splitLengthMeters)
    }

    // MARK: - Split pace (N7)

    /// The average pace across one split bucket — Δtime ÷ Δdistance — in seconds per
    /// kilometre, regardless of the bucket's own unit.
    ///
    /// This is what the split chart, the splits table, and the share card's "fastest
    /// split" callout all claim to show. The tracker used to store whatever
    /// `currentPaceSecondsPerKm` happened to hold at the instant a boundary was
    /// crossed: outdoors the *instantaneous* speed of a single GPS fix, indoors the
    /// *cumulative session average* (so every indoor split reported the same number
    /// and a negative-split run rendered flat).
    ///
    /// Returns `nil` for a bucket with no measurable distance or non-positive
    /// elapsed time, so callers fall back rather than store an infinite pace.
    static func splitPaceSecondsPerKm(deltaSeconds: Double, deltaMeters: Double) -> Double? {
        guard deltaSeconds > 0, deltaMeters > 0,
              deltaSeconds.isFinite, deltaMeters.isFinite else { return nil }
        return deltaSeconds / deltaMeters * 1_000
    }
}

// MARK: - Splits from a recorded distance series (N9)

extension SplitBucketing {

    /// One cumulative distance reading from a recorded workout: how far the runner had
    /// covered in total, and how far into the workout that reading was taken.
    struct DistancePoint: Sendable, Equatable {
        var elapsedSeconds: Double
        var cumulativeMeters: Double

        init(elapsedSeconds: Double, cumulativeMeters: Double) {
            self.elapsedSeconds = elapsedSeconds
            self.cumulativeMeters = cumulativeMeters
        }
    }

    /// Buckets a workout's distance series into `Split`s, the same way the live tracker
    /// buckets a run as it happens.
    ///
    /// Imported runs previously had no splits at all, so an Apple Watch user — whose
    /// runs *all* arrive by import — never saw the split pace chart, the split HR or
    /// elevation charts, the splits table, or split bars on the share card, and
    /// `WorkoutAnalyticsService.intervalEffortPace` fell back to the session average
    /// (the misclassification H2.1 fixed). HealthKit's distance samples carry their own
    /// timestamps, which is all this needs.
    ///
    /// A sample covers an interval rather than an instant, so the moment a boundary is
    /// crossed is interpolated linearly inside the sample that spans it. Buckets whose
    /// timing cannot be established are dropped rather than stored with a zero pace.
    ///
    /// - Parameters:
    ///   - points: cumulative distance readings, in any order.
    ///   - splitLengthMeters: bucket size, from the runner's unit preference.
    ///   - heartRateSamples: the workout's heart-rate series, if it has one.
    ///   - totalDurationSeconds: the workout's full duration; defaults to the last reading.
    static func splits(
        from points: [DistancePoint],
        splitLengthMeters: Double,
        heartRateSamples: [Double] = [],
        totalDurationSeconds: Double? = nil
    ) -> [Split] {
        guard splitLengthMeters > 0 else { return [] }

        // Chronological, finite, and never running backwards — a distance series that
        // dips would otherwise re-cross a boundary it already passed. Non-finite
        // readings are dropped before sorting, so they can't corrupt the ordering.
        let ordered = points
            .filter { $0.elapsedSeconds.isFinite && $0.cumulativeMeters.isFinite }
            .sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        var series: [DistancePoint] = []
        for point in ordered {
            let seconds = max(0, point.elapsedSeconds)
            let meters = max(point.cumulativeMeters, series.last?.cumulativeMeters ?? 0)
            if let last = series.last, last.elapsedSeconds == seconds {
                series[series.count - 1] = DistancePoint(elapsedSeconds: seconds, cumulativeMeters: meters)
            } else {
                series.append(DistancePoint(elapsedSeconds: seconds, cumulativeMeters: meters))
            }
        }
        guard let lastReading = series.last,
              lastReading.cumulativeMeters >= splitLengthMeters else { return [] }

        let totalSeconds = totalDurationSeconds ?? lastReading.elapsedSeconds
        var result: [Split] = []
        var previous = DistancePoint(elapsedSeconds: 0, cumulativeMeters: 0)
        var bucketStartSeconds: Double = 0
        var completedBuckets = 0

        for point in series {
            defer { previous = point }
            let bucketsAtPoint = bucketIndex(
                distanceMeters: point.cumulativeMeters, splitLengthMeters: splitLengthMeters
            )
            guard bucketsAtPoint > completedBuckets else { continue }

            let spanMeters = point.cumulativeMeters - previous.cumulativeMeters
            let spanSeconds = point.elapsedSeconds - previous.elapsedSeconds

            while completedBuckets < bucketsAtPoint {
                completedBuckets += 1
                let boundaryMeters = Double(completedBuckets) * splitLengthMeters
                let crossedAt: Double
                if spanMeters > 0 {
                    let fraction = (boundaryMeters - previous.cumulativeMeters) / spanMeters
                    crossedAt = previous.elapsedSeconds + spanSeconds * min(max(fraction, 0), 1)
                } else {
                    crossedAt = point.elapsedSeconds
                }
                if let pace = splitPaceSecondsPerKm(
                    deltaSeconds: crossedAt - bucketStartSeconds,
                    deltaMeters: splitLengthMeters
                ) {
                    result.append(
                        Split(
                            kilometer: completedBuckets,
                            paceSecondsPerKm: pace,
                            heartRate: averageHeartRate(
                                samples: heartRateSamples,
                                fromSeconds: bucketStartSeconds,
                                toSeconds: crossedAt,
                                totalSeconds: totalSeconds
                            ),
                            elevationGainMeters: 0,
                            cumulativeDistanceMeters: boundaryMeters
                        )
                    )
                }
                bucketStartSeconds = crossedAt
            }
        }
        return result
    }

    /// Mean heart rate over the `fromSeconds ..< toSeconds` window of a workout.
    ///
    /// A workout's heart-rate series is persisted as a bare ordered array with no
    /// timestamps of its own, so samples are mapped onto the run's timeline by
    /// position — evenly spaced, the same assumption the HealthKit export makes when
    /// it lays them back out (`HealthKitRepository.sampleTimestamps`). An
    /// approximation, but a better one than leaving every imported split without a
    /// heart rate and the split HR chart permanently hidden.
    static func averageHeartRate(
        samples: [Double],
        fromSeconds: Double,
        toSeconds: Double,
        totalSeconds: Double
    ) -> Double? {
        guard !samples.isEmpty, totalSeconds > 0, toSeconds > fromSeconds else { return nil }
        let count = Double(samples.count)
        let lower = Int((max(0, fromSeconds) / totalSeconds * count).rounded(.down))
        let upper = Int((min(totalSeconds, max(0, toSeconds)) / totalSeconds * count).rounded(.up))
        let start = min(max(0, lower), samples.count - 1)
        let end = min(max(start + 1, upper), samples.count)
        let window = samples[start..<end]
        return window.reduce(0, +) / Double(window.count)
    }
}
