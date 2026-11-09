import Foundation

// MARK: - CoursePacing

/// Goal-time splits for a real course: slower up the hills, quicker down them, at the
/// same effort throughout, and adding up to the goal time exactly.
///
/// ## The model
///
/// Minetti et al. (2002), "Energy cost of walking and running at extreme uphill and
/// downhill slopes", *Journal of Applied Physiology* 93(3):1039–1046. Their fit for the
/// metabolic cost of running on a grade *i* (rise over run), in J per kg per metre:
///
///     C(i) = 155.4 i⁵ − 30.4 i⁴ − 43.3 i³ + 46.3 i² + 19.5 i + 3.6
///
/// Flat ground costs 3.6. Even effort means even metabolic power, and power is cost per
/// metre times speed, so the time a stretch should take is proportional to its cost per
/// metre times its length. Every stretch's share of the goal time is its share of the
/// whole course's cost. That is the plan: no other tuning, and no constant of our own.
///
/// It is the most-cited published model and the basis of several grade-adjusted pace
/// tools. It is known to credit descents generously — measured on a treadmill, it assumes
/// a runner turns all of a descent's saving into speed. On a road course the grades are
/// small and the window this smooths over is long, so the effect is seconds a kilometre,
/// but it is the first place to look if splits read too quick downhill.
///
/// Pure, like ``RaceDayPlan``: the hub hands over the course, the goal and the unit.
enum CoursePacing {

    /// Grades beyond this are clamped. Minetti measured to ±45 %; a road race has nothing
    /// near ±30 %, so only a GPS spike gets here, and it should not dominate a split.
    static let maximumGrade = 0.30

    /// How far a course's own length may sit from the race distance and still be taken
    /// for that race. A course file drawn on a map is usually within a few per cent of
    /// the measured distance; a half-marathon file against a marathon goal is not.
    static let lengthTolerance = 0.10

    /// Cost of running on a grade, in J/(kg·m) — Minetti et al. (2002).
    static func costOfRunning(grade: Double) -> Double {
        let slope = min(max(grade, -maximumGrade), maximumGrade)
        return ((((155.4 * slope - 30.4) * slope - 43.3) * slope + 46.3) * slope + 19.5) * slope + 3.6
    }

    /// Pace on a grade relative to flat ground at the same effort: 1.11 on a 2 % climb,
    /// 0.90 on a 2 % descent.
    static func relativePace(grade: Double) -> Double {
        costOfRunning(grade: grade) / costOfRunning(grade: 0)
    }

    /// Whether a course is plausibly the race it is being paced for.
    static func matches(_ course: RaceCourse, distanceMeters: Double) -> Bool {
        guard distanceMeters > 0, course.lengthMeters > 0 else { return false }
        return abs(course.lengthMeters - distanceMeters) / distanceMeters <= lengthTolerance
    }

    /// The split table for a goal time over a course, with the same markers as the
    /// even-pace table (``RaceDayPlan/splits(distanceMeters:paceSecondsPerKm:unit:)``) so
    /// the two read row for row. Empty when the course does not match the distance.
    ///
    /// The course is stretched or shrunk to the race distance: a file a few hundred
    /// metres off still has its hills in the right places, and the markers are the race's.
    static func splits(
        course: RaceCourse,
        distanceMeters: Double,
        finishSeconds: TimeInterval,
        unit: UnitPreference
    ) -> [RaceSplit] {
        guard matches(course, distanceMeters: distanceMeters),
              finishSeconds > 0, finishSeconds.isFinite else { return [] }

        let markers = RaceDayPlan.splits(
            distanceMeters: distanceMeters,
            paceSecondsPerKm: finishSeconds / (distanceMeters / 1_000),
            unit: unit
        )
        guard let clock = Clock(course: course, distanceMeters: distanceMeters, finishSeconds: finishSeconds) else {
            return []
        }

        var previousElevation = clock.elevation(atRaceMeters: 0)
        return markers.map { marker in
            let elevation = clock.elevation(atRaceMeters: marker.distanceMeters)
            defer { previousElevation = elevation }
            return RaceSplit(
                marker: marker.marker,
                distanceMeters: marker.distanceMeters,
                isPartial: marker.isPartial,
                // The last row is the finish; pin it to the goal so rounding cannot leave
                // the table a fraction of a second off the time the runner set.
                elapsedSeconds: marker.distanceMeters >= distanceMeters ? finishSeconds : clock.elapsed(atRaceMeters: marker.distanceMeters),
                elevationChangeMeters: elevation - previousElevation
            )
        }
    }

    // MARK: - Clock

    /// Elapsed time along the course at even effort, with the course scaled to the race.
    struct Clock {
        /// Race distance at each profile sample.
        private let distances: [Double]
        /// Elapsed seconds at each profile sample.
        private let times: [Double]
        private let elevations: [Double]

        init?(course: RaceCourse, distanceMeters: Double, finishSeconds: TimeInterval) {
            let samples = course.samples
            guard samples.count >= 2, course.lengthMeters > 0 else { return nil }
            let scale = distanceMeters / course.lengthMeters

            // Each stretch's cost, from the grade the file draws (its own geometry, not
            // the scaled one: the hill is as steep as it is, wherever the markers fall).
            var weights: [Double] = []
            weights.reserveCapacity(samples.count - 1)
            for index in 1..<samples.count {
                let run = samples[index].distanceMeters - samples[index - 1].distanceMeters
                guard run > 0 else { weights.append(0); continue }
                let grade = (samples[index].elevationMeters - samples[index - 1].elevationMeters) / run
                weights.append(CoursePacing.costOfRunning(grade: grade) * run * scale)
            }
            let total = weights.reduce(0, +)
            guard total > 0, total.isFinite else { return nil }

            let secondsPerWeight = finishSeconds / total
            var times: [Double] = [0]
            times.reserveCapacity(samples.count)
            for weight in weights { times.append(times[times.count - 1] + weight * secondsPerWeight) }

            self.distances = samples.map { $0.distanceMeters * scale }
            self.times = times
            self.elevations = samples.map(\.elevationMeters)
        }

        func elapsed(atRaceMeters distance: Double) -> Double {
            interpolate(times, at: distance)
        }

        func elevation(atRaceMeters distance: Double) -> Double {
            interpolate(elevations, at: distance)
        }

        private func interpolate(_ values: [Double], at distance: Double) -> Double {
            guard let first = distances.first, let last = distances.last else { return 0 }
            if distance <= first { return values[0] }
            if distance >= last { return values[values.count - 1] }

            // First sample at or past the distance, by binary search.
            var low = 0
            var high = distances.count - 1
            while low < high {
                let mid = (low + high) / 2
                if distances[mid] < distance { low = mid + 1 } else { high = mid }
            }
            let upper = low
            let lower = max(0, upper - 1)
            let span = distances[upper] - distances[lower]
            guard span > 0 else { return values[upper] }
            let fraction = (distance - distances[lower]) / span
            return values[lower] + (values[upper] - values[lower]) * fraction
        }
    }
}
