import Foundation

// MARK: - Training Paces

struct TrainingPaces: Sendable {
    /// Easy run pace range (seconds/km). Lower = faster.
    var easyRange: ClosedRange<Double>
    /// Marathon pace (seconds/km).
    var marathon: Double
    /// Threshold / tempo pace (seconds/km).
    var threshold: Double
    /// Interval pace (seconds/km).
    var interval: Double
    /// Short repetition pace (seconds/km).
    var repetition: Double
}

// MARK: - PaceCalculatorService

/// Pure, stateless service implementing Jack Daniels' VDOT methodology.
///
/// References:
/// - Daniels, J. (2014). *Daniels' Running Formula* (3rd ed.)
/// - VO₂ at speed: `VO₂ = 0.000104v² + 0.182258v − 4.60`  (v in m/min)
/// - %VO₂max at time t (min): `0.8 + 0.1894393·e^(−0.012778t) + 0.2989558·e^(−0.1932605t)`
/// - VDOT = VO₂ / %VO₂max
enum PaceCalculatorService {

    // MARK: Core VDOT equations

    /// VO₂ demand for a given running speed (m/min).
    static func vo2(forSpeedMetersPerMinute speed: Double) -> Double {
        -4.60 + 0.182258 * speed + 0.000104 * speed * speed
    }

    /// Fraction of VO₂max that can be sustained for `duration` minutes.
    static func fractionVO2max(forDurationMinutes duration: Double) -> Double {
        0.8
        + 0.1894393 * exp(-0.012778 * duration)
        + 0.2989558 * exp(-0.1932605 * duration)
    }

    // MARK: VDOT from race result

    /// Derives VDOT from a known race performance.
    ///
    /// Returns 0 for degenerate input (non-positive time or distance) rather than
    /// ∞/NaN, so callers that guard on `v > 0` / `v.isFinite` reject it cleanly and
    /// comparators (e.g. sorting workouts by VDOT) stay well-defined.
    static func vdot(distanceMeters: Double, timeSeconds: Double) -> Double {
        guard timeSeconds > 0, distanceMeters > 0 else { return 0 }
        let timeMinutes = timeSeconds / 60
        let speed = distanceMeters / timeMinutes
        return vo2(forSpeedMetersPerMinute: speed) / fractionVO2max(forDurationMinutes: timeMinutes)
    }

    // MARK: Race prediction

    /// Predicts finish time (seconds) for a given distance using binary search.
    static func predictedTime(vdot: Double, distanceMeters: Double) -> TimeInterval {
        var lo = 1.0          // 1 minute
        var hi = 600.0        // 10 hours
        for _ in 0..<64 {
            let mid = (lo + hi) / 2
            let speed = distanceMeters / mid
            let computed = vo2(forSpeedMetersPerMinute: speed)
                           / fractionVO2max(forDurationMinutes: mid)
            if computed > vdot { lo = mid } else { hi = mid }
        }
        return ((lo + hi) / 2) * 60
    }

    // MARK: Training paces

    /// Returns all training paces derived from a runner's VDOT.
    ///
    /// The fractions are Daniels' %VO₂max intensities for each training zone.
    static func trainingPaces(forVDOT vdot: Double) -> TrainingPaces {
        TrainingPaces(
            easyRange: paceRange(fractionLo: 0.59, fractionHi: 0.74, vdot: vdot),
            marathon: pace(fraction: 0.79, vdot: vdot),
            threshold: pace(fraction: 0.86, vdot: vdot),
            interval: pace(fraction: 0.975, vdot: vdot),
            repetition: pace(fraction: 1.10, vdot: vdot)
        )
    }

    /// Convenience: derive training paces directly from a 5 K time (seconds).
    static func trainingPaces(from5KTimeSeconds time: Double) -> TrainingPaces {
        let v = vdot(distanceMeters: 5_000, timeSeconds: time)
        return trainingPaces(forVDOT: v)
    }

    // MARK: Race pace prediction

    /// Returns predicted race pace (sec/km) for `raceDistanceMeters`, derived
    /// from a single workout's distance and duration via VDOT. Returns nil if
    /// the workout is too short (< 1.5 km), duration is invalid, or VDOT is degenerate.
    static func predictedRacePaceSecondsPerKm(
        workoutDistanceMeters: Double,
        workoutDurationSeconds: Double,
        raceDistanceMeters: Double
    ) -> Double? {
        guard workoutDistanceMeters >= 1_500, workoutDurationSeconds > 0 else { return nil }
        let v = vdot(distanceMeters: workoutDistanceMeters, timeSeconds: workoutDurationSeconds)
        guard v > 0, v.isFinite else { return nil }
        let predictedSeconds = predictedTime(vdot: v, distanceMeters: raceDistanceMeters)
        return predictedSeconds / (raceDistanceMeters / 1_000)
    }

    /// OLS slope for an array of (x, y) pairs. Returns nil for fewer than 2 points
    /// or zero x-variance. When x is `timeIntervalSinceReferenceDate`, slope is in
    /// y-units per second.
    static func linearRegressionSlope(_ points: [(x: Double, y: Double)]) -> Double? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let xMean = points.reduce(0) { $0 + $1.x } / n
        let yMean = points.reduce(0) { $0 + $1.y } / n
        let sxy = points.reduce(0) { $0 + ($1.x - xMean) * ($1.y - yMean) }
        let sxx = points.reduce(0) { $0 + ($1.x - xMean) * ($1.x - xMean) }
        guard sxx > 0 else { return nil }
        return sxy / sxx
    }

    // MARK: Helpers

    /// Seconds-per-km pace at a given fraction of VDOT.
    private static func pace(
        fraction: Double,
        vdot: Double
    ) -> Double {
        let speed = speedForFraction(fraction, vdot: vdot)
        return 60_000 / speed   // m/min → sec/km
    }

    private static func paceRange(
        fractionLo: Double,
        fractionHi: Double,
        vdot: Double
    ) -> ClosedRange<Double> {
        let faster = pace(fraction: fractionHi, vdot: vdot)
        let slower = pace(fraction: fractionLo, vdot: vdot)
        return faster...slower
    }

    /// Solves the quadratic VO₂ = 0.000104v² + 0.182258v − 4.60 for the speed (m/min)
    /// whose oxygen demand equals `fraction` of the runner's VDOT (VO₂max estimate).
    ///
    /// The intensity fractions passed here are already Daniels' %VO₂max values
    /// (e.g. 0.86 for threshold), so the target VO₂ is simply `fraction · vdot`.
    /// `fractionVO2max(forDurationMinutes:)` models the *sustainable* %VO₂max over a
    /// race of a given duration and belongs only in race-time prediction — applying it
    /// here too would double-discount and prescribe paces well slower than the Daniels
    /// tables (e.g. threshold ≈ 4:36/km instead of ≈ 4:20/km for VDOT 50).
    private static func speedForFraction(
        _ fraction: Double,
        vdot: Double
    ) -> Double {
        let targetVO2 = fraction * vdot
        let a = 0.000104, b = 0.182258, c = -(4.60 + targetVO2)
        let disc = b * b - 4 * a * c
        return (-b + sqrt(disc)) / (2 * a)
    }
}
