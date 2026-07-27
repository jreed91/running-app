import Foundation
import SwiftData

/// Seeds a realistic training history for UI tests that need populated screens.
///
/// `--uitesting` gives a clean in-memory store, which is the right default: a test
/// asserting on an empty state should not have to delete anything first. But it also
/// means History, Progress and the Dashboard's weekly bars render their empty states
/// forever, so a screenshot pass or a chart regression test has nothing to look at.
/// `--seed-demo-data` fills that gap, and is the only thing that turns this on.
///
/// What it aims at is a history a real runner would *plausibly* have after a few months,
/// because a screen fed only tidy data hides the bugs that matter:
///
/// - **Mixed provenance.** Roughly a third of the runs carry a `healthKitWorkoutID` and
///   are shaped exactly the way `HealthKitRepository.importRuns` shapes one — the same
///   fields set, the same ones left `nil`. Screens that treat an imported run differently
///   from a recorded one have both to render.
/// - **Ragged coverage.** Not every run has heart rate, a route, weather, or splits, and
///   the gaps do not line up. A card that assumes "if there is a run there is a pace"
///   fails here rather than in front of a user.
/// - **Indoor runs**, which have no route and no elevation, so the route and elevation
///   views get their genuinely-empty case with data all around it.
/// - **Strength sessions**, so the History list has to mix two workout kinds.
/// - **A missed week**, because an unbroken streak is the one history almost nobody has.
///
/// Deliberately deterministic — every value derives from the loop indices, with no
/// `random` calls and no clock reads beyond today's date — so two runs a minute apart
/// produce identical screens and a screenshot diff means a real change.
enum DemoDataSeed {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--seed-demo-data")
    }

    /// Weeks of history generated. Covers the 1M/3M/6M range filters on Progress with
    /// enough points either side of each boundary to tell them apart.
    private static let weeks = 18

    /// Weeks back that are skipped entirely — an illness or holiday gap. Chosen to sit
    /// inside the 3M window so the charts have to render a hole rather than a flat line.
    private static let missedWeeks: Set<Int> = [6, 7]

    /// One repeating training week: metres, then seconds per kilometre.
    private static let shape: [(type: WorkoutType, distance: Double, pace: Double)] = [
        (.easy, 5_800, 337),
        (.tempo, 8_200, 292),
        (.interval, 6_400, 306),
        (.longRun, 14_500, 363)
    ]

    /// Days into the week each session lands on, Monday-based.
    private static let dayOffsets = [1, 3, 5, 6]

    // MARK: - Entry point

    @MainActor
    static func populateIfNeeded(_ container: ModelContainer) {
        guard isEnabled else { return }
        let context = ModelContext(container)

        // Cheap guard against double-seeding if this is ever called twice in a launch.
        let existing = (try? context.fetchCount(FetchDescriptor<RunWorkout>())) ?? 0
        guard existing == 0 else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        for weeksAgo in 0..<weeks where !missedWeeks.contains(weeksAgo) {
            for (index, offset) in dayOffsets.enumerated() {
                let daysBack = weeksAgo * 7 + (7 - offset)
                guard daysBack > 0,
                      let day = calendar.date(byAdding: .day, value: -daysBack, to: today),
                      let date = calendar.date(byAdding: .hour, value: 7, to: day) else {
                    continue
                }
                context.insert(makeRun(shape[index], index: index, weeksAgo: weeksAgo, date: date))
            }

            // A strength session mid-week, most weeks — enough to mix the History list
            // without pretending the runner never skips one.
            if weeksAgo % 3 != 2 {
                let daysBack = weeksAgo * 7 + 5
                if daysBack > 0,
                   let day = calendar.date(byAdding: .day, value: -daysBack, to: today),
                   let date = calendar.date(byAdding: .hour, value: 18, to: day) {
                    context.insert(makeStrengthSession(weeksAgo: weeksAgo, date: date))
                }
            }
        }

        do {
            try context.save()
        } catch {
            AppLogger.log("Demo data seed failed to save: \(error)", label: "UITest", level: .error)
        }
    }

    // MARK: - Runs

    @MainActor
    private static func makeRun(
        _ session: (type: WorkoutType, distance: Double, pace: Double),
        index: Int,
        weeksAgo: Int,
        date: Date
    ) -> RunWorkout {
        // A steady improvement toward the present plus week-to-week noise, so the pace
        // and VDOT charts show a real trend rather than a flat line. `weeksAgo` counts
        // backwards, so older weeks are slower and shorter.
        let drift = 1.0 + (Double(weeksAgo) * 0.006)
        let wobble = 1.0 + (Double((weeksAgo * 7 + index) % 5) - 2.0) * 0.012
        let distance = session.distance
            * (1.0 + (Double((index + weeksAgo) % 3) - 1.0) * 0.05)
            / drift
        let paceSecondsPerKm = session.pace * drift * wobble
        let duration = distance / 1_000 * paceSecondsPerKm

        // Every fifth easy run is on a treadmill: no route, no elevation, and — because
        // an indoor run has no GPS to derive them from — no splits either.
        let isIndoor = session.type == .easy && weeksAgo % 5 == 1
        // Imported runs are the ones the runner recorded on a watch. Shaped the way
        // `HealthKitRepository.importRuns` shapes one, down to which fields stay nil.
        let isImported = (weeksAgo + index) % 3 == 0

        let run = RunWorkout(
            date: date,
            distanceMeters: distance,
            durationSeconds: duration,
            workoutType: session.type,
            workoutLocation: isIndoor ? .indoor : .outdoor
        )

        // Heart rate is missing on a slice of runs — a strap that did not connect, or a
        // phone-only run. Screens must not assume a pace implies a heart rate.
        let hasHeartRate = (weeksAgo + index) % 7 != 3
        if hasHeartRate {
            let average = 138 + Double((index * 9 + weeksAgo) % 22)
            run.averageHeartRate = average
            run.maxHeartRate = average + 18
            run.heartRateSamples = heartRateSamples(around: average, count: min(Int(duration / 30), 90))
        }

        if !isIndoor {
            run.elevationGainMeters = 20 + Double((index * 13 + weeksAgo) % 90)
            run.splits = splits(
                distanceMeters: distance,
                paceSecondsPerKm: paceSecondsPerKm,
                averageHeartRate: run.averageHeartRate,
                weeksAgo: weeksAgo
            )
            run.splitUnit = .metric

            // Routes only on the runs that had GPS worth keeping — a recorded outdoor run
            // or an imported one whose HealthKit route came across.
            if (weeksAgo + index) % 4 != 1 {
                run.routeCoordinates = route(distanceMeters: distance, seed: weeksAgo * 4 + index)
            }
        }

        if isImported {
            run.healthKitWorkoutID = "demo-hk-\(weeksAgo)-\(index)"
        } else {
            // WeatherKit only ever attaches to a run this app recorded itself; an
            // imported one arrives without it.
            run.weather = weather(weeksAgo: weeksAgo, index: index)
        }

        if session.type == .longRun && weeksAgo % 4 == 0 {
            run.notes = "Felt strong through the second half."
        }

        return run
    }

    /// A plausible bpm trace: a warm-up ramp onto the run's average, then drift upward
    /// with small oscillations. Enough shape for the HR chart to be worth looking at.
    private static func heartRateSamples(around average: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (0..<count).map { sample in
            let progress = Double(sample) / Double(count)
            let warmUp = progress < 0.12 ? -22 * (1 - progress / 0.12) : 0
            let drift = progress * 9
            let oscillation = Double((sample % 7) - 3) * 1.4
            return (average + warmUp + drift + oscillation).rounded()
        }
    }

    /// One split per kilometre, with the last one short where the run does not land on a
    /// whole kilometre — which is how a real run almost always ends.
    private static func splits(
        distanceMeters: Double,
        paceSecondsPerKm: Double,
        averageHeartRate: Double?,
        weeksAgo: Int
    ) -> [Split] {
        let whole = Int(distanceMeters / 1_000)
        guard whole > 0 else { return [] }
        return (1...whole).map { km in
            // Negative split: the back half a little quicker than the front.
            let position = Double(km) / Double(whole)
            let pace = paceSecondsPerKm * (1.03 - position * 0.06)
                + Double((km + weeksAgo) % 5) - 2
            return Split(
                kilometer: km,
                paceSecondsPerKm: pace,
                heartRate: averageHeartRate.map { $0 + position * 8 + Double((km % 3) - 1) * 2 },
                elevationGainMeters: Double((km * 7 + weeksAgo) % 14),
                cumulativeDistanceMeters: Double(km) * 1_000
            )
        }
    }

    /// A closed loop near Des Moines, sized roughly to the run's distance. Enough points
    /// that the route map and its snapshot have a real shape to draw.
    private static func route(distanceMeters: Double, seed: Int) -> [Coordinate] {
        let centreLat = 41.5868 + Double(seed % 5) * 0.004
        let centreLon = -93.6250 - Double(seed % 7) * 0.004
        // ~111km per degree of latitude; a loop's radius is its circumference over 2π.
        let radiusDegrees = (distanceMeters / (2 * .pi)) / 111_000
        let points = 60
        return (0..<points).map { step in
            let angle = (Double(step) / Double(points)) * 2 * .pi
            // Squashed and wobbled so it reads as a route rather than a perfect circle.
            let wobble = 1 + sin(angle * 3 + Double(seed)) * 0.18
            return Coordinate(
                .init(
                    latitude: centreLat + sin(angle) * radiusDegrees * wobble,
                    longitude: centreLon + cos(angle) * radiusDegrees * 1.3 * wobble
                )
            )
        }
    }

    private static func weather(weeksAgo: Int, index: Int) -> WorkoutWeather {
        let conditions: [(String, String)] = [
            ("sun.max.fill", "Clear"),
            ("cloud.sun.fill", "Partly Cloudy"),
            ("cloud.fill", "Cloudy"),
            ("cloud.drizzle.fill", "Light Rain")
        ]
        let condition = conditions[(weeksAgo + index) % conditions.count]
        // Cooler the further back we go, as if running from summer into spring.
        let temperature = 24 - Double(weeksAgo) * 0.7 + Double((index % 3) - 1) * 2
        return WorkoutWeather(
            temperatureCelsius: temperature,
            feelsLikeCelsius: temperature - Double(index % 2) * 1.5,
            humidityPercent: 52 + Double((weeksAgo * 3 + index) % 34),
            windSpeedKmh: 6 + Double((weeksAgo + index * 2) % 17),
            conditionSymbol: condition.0,
            conditionDescription: condition.1
        )
    }

    // MARK: - Strength

    @MainActor
    private static func makeStrengthSession(weeksAgo: Int, date: Date) -> StrengthWorkout {
        let workout = StrengthWorkout(
            date: date,
            durationSeconds: Double(1_800 + (weeksAgo % 4) * 300),
            notes: weeksAgo % 4 == 1 ? "Went up a rung on the squats." : nil
        )

        // Four exercises, three sets each, with the odd set skipped the way a real
        // session ends when time runs out.
        workout.completedSets = (0..<4).flatMap { exercise in
            (0..<3).map { set in
                let skipped = exercise == 3 && set == 2 && weeksAgo % 3 == 0
                return CompletedStrengthSet(
                    exerciseIndex: exercise,
                    setIndex: set,
                    completedReps: skipped ? 0 : 8 + (exercise + set) % 5,
                    actualWeight: exercise < 2 ? "\(40 + exercise * 15 + (weeksAgo % 3) * 5) kg" : nil,
                    skipped: skipped
                )
            }
        }

        // Strength sessions sync from HealthKit too, on the same cadence as the runs.
        if weeksAgo % 3 == 0 {
            workout.healthKitWorkoutID = "demo-hk-strength-\(weeksAgo)"
        }
        return workout
    }
}
