import Foundation

// MARK: - RunAnalysis

/// The whole run as one timeline for the run analysis page: pace, heart rate and elevation
/// at evenly spaced points along the distance, so three stacked charts can share one x
/// axis and one finger, and the map can follow it.
///
/// What a run stores, and what each line is built from:
///
/// - **Distance series** (`RunWorkout.distanceSeries`): a cumulative reading every 10 m
///   with elapsed time and, for GPS runs, altitude. It gives the x axis, the time at each
///   point, pace and elevation.
/// - **Heart rate** (`RunWorkout.heartRateSamples`): bare bpm values with no timestamps,
///   so they are laid evenly across the run's duration, the same assumption
///   `HealthKitRepository.sampleTimestamps` makes for routes.
/// - **Route** (`RunWorkout.routeCoordinates`): coordinates with no timestamps either, so
///   the map marker is placed by elapsed-time fraction in the same way.
///
/// Pure and `Sendable`; tested without the app.
public enum RunAnalysis {

    public struct Reading: Equatable, Sendable {
        public let elapsedSeconds: Double
        public let meters: Double
        public let altitudeMeters: Double?

        public init(
            elapsedSeconds: Double,
            meters: Double,
            altitudeMeters: Double?
        ) {
            self.elapsedSeconds = elapsedSeconds
            self.meters = meters
            self.altitudeMeters = altitudeMeters
        }
    }

    /// One point on the shared timeline.
    public struct Point: Equatable, Sendable, Identifiable {
        public let meters: Double
        public let elapsedSeconds: Double
        /// Seconds per km over the surrounding ``paceWindowMeters``, or `nil` while
        /// standing still or before there is enough distance to say.
        public let paceSecondsPerKm: Double?
        public let heartRate: Double?
        public let altitudeMeters: Double?

        public var id: Double { meters }

        public init(
            meters: Double,
            elapsedSeconds: Double,
            paceSecondsPerKm: Double?,
            heartRate: Double?,
            altitudeMeters: Double?
        ) {
            self.meters = meters
            self.elapsedSeconds = elapsedSeconds
            self.paceSecondsPerKm = paceSecondsPerKm
            self.heartRate = heartRate
            self.altitudeMeters = altitudeMeters
        }
    }

    /// How many points the charts draw: enough to show a surge, few enough to scrub
    /// smoothly on a marathon.
    public static let targetPointCount = 240
    /// Pace is averaged over this much distance either side of a point, so GPS wobble
    /// over 10 m doesn't read as a sprint.
    public static let paceWindowMeters = 100.0
    /// Slower than this is a stop, not a pace: 30:00 per km.
    public static let slowestPaceSecondsPerKm = 1_800.0

    /// The run resampled onto evenly spaced distances. Empty when the series is too short
    /// to draw.
    public static func points(
        readings: [Reading],
        heartRateSamples: [Double],
        durationSeconds: Double
    ) -> [Point] {
        let series = cleaned(readings)
        guard let total = series.last?.meters, total >= 200, series.count >= 3 else { return [] }

        let step = max(10, total / Double(targetPointCount))
        // Multiplied rather than summed, so rounding never leaves the last point a hair
        // short of the finish.
        let count = Int((total / step).rounded(.up))
        var points: [Point] = []
        for index in 0...count {
            let at = min(Double(index) * step, total)
            let elapsed = time(at: at, in: series)
            points.append(Point(
                meters: at,
                elapsedSeconds: elapsed,
                paceSecondsPerKm: pace(around: at, total: total, in: series),
                heartRate: heartRate(atElapsed: elapsed, duration: durationSeconds, samples: heartRateSamples),
                altitudeMeters: altitude(at: at, in: series)
            ))
        }
        return points
    }

    /// The point nearest a distance along the run.
    public static func point(nearest meters: Double, in points: [Point]) -> Point? {
        guard !points.isEmpty else { return nil }
        // Evenly spaced, so the index is arithmetic, then checked either side.
        let step = points.count > 1 ? points[1].meters - points[0].meters : 1
        let guess = Int((meters / max(step, 0.001)).rounded())
        let candidates = [guess - 1, guess, guess + 1].filter { points.indices.contains($0) }
        return candidates.map { points[$0] }.min { abs($0.meters - meters) < abs($1.meters - meters) }
            ?? (meters <= 0 ? points.first : points.last)
    }

    /// Which route coordinate the runner was at after `elapsedSeconds`, assuming the
    /// coordinates are spread evenly over the run's duration.
    public static func routeIndex(atElapsed elapsedSeconds: Double, duration: Double, coordinateCount: Int) -> Int? {
        guard coordinateCount > 0, duration > 0 else { return nil }
        let fraction = min(max(elapsedSeconds / duration, 0), 1)
        return min(coordinateCount - 1, Int((fraction * Double(coordinateCount - 1)).rounded()))
    }

    // MARK: Internals

    private static func cleaned(_ readings: [Reading]) -> [Reading] {
        var result: [Reading] = [Reading(elapsedSeconds: 0, meters: 0, altitudeMeters: nil)]
        for reading in readings.sorted(by: { $0.elapsedSeconds < $1.elapsedSeconds }) {
            guard reading.elapsedSeconds.isFinite, reading.meters.isFinite,
                  let last = result.last,
                  reading.elapsedSeconds > last.elapsedSeconds,
                  reading.meters >= last.meters else { continue }
            result.append(reading)
        }
        return result
    }

    /// Index of the last reading at or before `meters`.
    private static func index(atOrBefore meters: Double, in series: [Reading]) -> Int {
        var low = 0
        var high = series.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if series[mid].meters <= meters { low = mid } else { high = mid - 1 }
        }
        return low
    }

    public static func time(at meters: Double, in series: [Reading]) -> Double {
        let lower = index(atOrBefore: meters, in: series)
        guard lower + 1 < series.count else { return series[lower].elapsedSeconds }
        let before = series[lower]
        let after = series[lower + 1]
        let span = after.meters - before.meters
        guard span > 0 else { return before.elapsedSeconds }
        return before.elapsedSeconds + (meters - before.meters) / span * (after.elapsedSeconds - before.elapsedSeconds)
    }

    private static func pace(around meters: Double, total: Double, in series: [Reading]) -> Double? {
        let start = max(0, meters - paceWindowMeters)
        let end = min(total, meters + paceWindowMeters)
        let distance = end - start
        guard distance >= paceWindowMeters else { return nil }
        let seconds = time(at: end, in: series) - time(at: start, in: series)
        guard seconds > 0 else { return nil }
        let pace = seconds / distance * 1_000
        return pace <= slowestPaceSecondsPerKm ? pace : nil
    }

    private static func altitude(at meters: Double, in series: [Reading]) -> Double? {
        let lower = index(atOrBefore: meters, in: series)
        // The nearest readings either side that carry an altitude.
        let before = series[...lower].last { $0.altitudeMeters != nil }
        let after = series[(lower + 1)...].first { $0.altitudeMeters != nil }
        switch (before, after) {
        case let (before?, after?):
            guard let low = before.altitudeMeters, let high = after.altitudeMeters else { return nil }
            let span = after.meters - before.meters
            guard span > 0 else { return low }
            return low + (meters - before.meters) / span * (high - low)
        case let (before?, nil): return before.altitudeMeters
        case let (nil, after?): return after.altitudeMeters
        default: return nil
        }
    }

    private static func heartRate(atElapsed elapsed: Double, duration: Double, samples: [Double]) -> Double? {
        let usable = samples.count
        guard usable > 0, duration > 0 else { return nil }
        let fraction = min(max(elapsed / duration, 0), 1)
        let index = min(usable - 1, Int((fraction * Double(usable - 1)).rounded()))
        // A few samples either side, so one dropout or spike doesn't show as a cliff.
        let window = samples[max(0, index - 2)...min(usable - 1, index + 2)].filter { $0 > 0 }
        guard !window.isEmpty else { return nil }
        return window.reduce(0, +) / Double(window.count)
    }
}
