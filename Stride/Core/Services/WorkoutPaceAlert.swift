import Foundation

/// Pure conversion from a coaching *pace* target into the *speed* range a
/// WorkoutKit `SpeedRangeAlert` needs, so a scheduled Watch workout coaches the
/// runner's pace per segment instead of only stepping structure.
///
/// Kept free of WorkoutKit so the (inverse, easy-to-get-wrong) pace→speed maths
/// is unit-testable; the thin `SpeedRangeAlert` construction lives at the call
/// site in ``HealthKitRepository``.
enum WorkoutPaceAlert {

    /// Converts a target pace (seconds/km) into a speed range in metres/second.
    ///
    /// Pace and speed are inverses — a *slower* pace (larger sec/km) is a
    /// *lower* speed — so the band's lower speed bound comes from the slow edge
    /// and the upper from the fast edge. `toleranceSecondsPerKm` widens the band
    /// symmetrically in pace space.
    ///
    /// Returns `nil` for a non-positive pace so the caller attaches no alert.
    static func speedRangeMetersPerSecond(
        forPaceSecondsPerKm pace: Double,
        toleranceSecondsPerKm tolerance: Double = 8
    ) -> ClosedRange<Double>? {
        guard pace > 0 else { return nil }
        let tol = max(0, tolerance)
        let slowPace = pace + tol                 // larger pace  -> lower speed bound
        let fastPace = max(1, pace - tol)         // smaller pace -> upper speed bound
        let lowerSpeed = 1_000.0 / slowPace
        let upperSpeed = 1_000.0 / fastPace
        guard lowerSpeed > 0, upperSpeed >= lowerSpeed else { return nil }
        return lowerSpeed...upperSpeed
    }
}
