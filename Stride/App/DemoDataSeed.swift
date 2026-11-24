import Foundation
import CoreLocation
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

    /// `--seed-coach-read`, on top of `--seed-demo-data`: turns AI Coach on and stores a
    /// finished coach read on the newest run, so the coach page can be captured.
    ///
    /// The App Store screenshots run on a CI simulator, which has no Apple Intelligence,
    /// so a real read can never be written there. This one is sample text, written to
    /// agree with the seeded run it sits on (see `coachRead(metric:)`). Only
    /// `AppStoreScreenshotTests.testCaptureCoachScreen` passes the flag.
    static var seedsCoachRead: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("--seed-coach-read")
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
        var newestRun: RunWorkout?

        for weeksAgo in 0..<weeks where !missedWeeks.contains(weeksAgo) {
            for (index, offset) in dayOffsets.enumerated() {
                let daysBack = weeksAgo * 7 + (7 - offset)
                guard daysBack > 0,
                      let day = calendar.date(byAdding: .day, value: -daysBack, to: today),
                      let date = calendar.date(byAdding: .hour, value: 7, to: day) else {
                    continue
                }
                let run = makeRun(shape[index], index: index, weeksAgo: weeksAgo, date: date)
                context.insert(run)
                if newestRun.map({ run.date > $0.date }) ?? true {
                    newestRun = run
                }
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

        if seedsCoachRead, let newestRun {
            newestRun.cachedAIInsight = coachRead(metric: UnitPreference.localeDefault == .metric)
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
                // The GPS distance trace a recorded run keeps, so Run analysis and best
                // efforts have something to read on the demo history too.
                run.distanceSeries = distanceSeries(
                    distanceMeters: distance,
                    durationSeconds: duration,
                    seed: weeksAgo * 4 + index
                )
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

    /// A reading every 10 s, shaped like a real run: pace drifting with fatigue and a few
    /// surges, slower up the two hills and quicker down them, then scaled so it ends on
    /// the run's distance. Deterministic per `seed`.
    private static func distanceSeries(
        distanceMeters: Double,
        durationSeconds: Double,
        seed: Int
    ) -> [SplitBucketing.DistancePoint] {
        guard durationSeconds > 0 else { return [] }
        let phase = Double(seed % 7)
        func altitude(_ progress: Double) -> Double {
            240 + 14 * sin(2 * .pi * 2 * progress + phase) + 4 * sin(2 * .pi * 5 * progress + phase * 2)
        }
        let times = Array(stride(from: 0.0, through: durationSeconds, by: 10))
        var cumulative: [Double] = [0]
        for (previous, elapsed) in zip(times, times.dropFirst()) {
            let progress = elapsed / durationSeconds
            let climbing = (altitude(progress) - altitude(previous / durationSeconds)) / 10
            let effort = 1
                + 0.025 * sin(2 * .pi * 1.3 * progress + phase)
                + 0.012 * sin(2 * .pi * 7.1 * progress + phase * 3)
                + 0.006 * sin(2 * .pi * 23.0 * progress + phase * 5)
                - 0.6 * climbing
            cumulative.append(cumulative[cumulative.count - 1] + max(effort, 0.5) * (elapsed - previous))
        }
        let scale = distanceMeters / max(cumulative[cumulative.count - 1], 1)
        return zip(times, cumulative).map { elapsed, raw in
            SplitBucketing.DistancePoint(
                elapsedSeconds: elapsed,
                cumulativeMeters: raw * scale,
                altitudeMeters: altitude(elapsed / durationSeconds)
            )
        }
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

    /// A loop (or out-and-back) from home along Des Moines' street grid, sized roughly to
    /// the run's distance. Two points a block, so maps and the heatmap have a real shape.
    private static func route(distanceMeters: Double, seed: Int) -> [Coordinate] {
        // Runs start from home and follow the street grid, the way a runner's week does:
        // a handful of favourite loops and one out-and-back, run again and again, so the
        // heatmap has real corridors rather than a tangle. Des Moines' west-side blocks are
        // about 160 m each way.
        let home = (lat: 41.6005, lon: -93.6520)
        let block = (lat: 160.0 / 111_000, lon: 160.0 / 83_000)
        let fixesPerBlock = 8
        let blocks = max(Int((distanceMeters / 160).rounded()), 4)

        // (east, north) unit steps of one block, walked in order and back home. Four
        // named loops a runner would actually keep, picked by distance, so most runs
        // share streets; every fifth run is an out-and-back along the same avenue.
        let loops: [[(dx: Int, dy: Int, count: Int)]] = [
            [(0, 1, 4), (1, 0, 3), (0, -1, 2), (1, 0, 2), (0, -1, 2), (-1, 0, 5)],
            [(0, 1, 4), (1, 0, 6), (0, -1, 1), (-1, 0, 2), (0, -1, 3), (-1, 0, 4)],
            [(0, 1, 4), (-1, 0, 8), (0, -1, 10), (1, 0, 3), (0, 1, 3), (1, 0, 5), (0, 1, 3)],
            [(0, 1, 12), (1, 0, 10), (0, -1, 4), (1, 0, 6), (0, -1, 14), (-1, 0, 8), (0, 1, 6), (-1, 0, 8)],
        ]
        func scaled(_ loop: [(dx: Int, dy: Int, count: Int)], _ factor: Int) -> [(dx: Int, dy: Int, count: Int)] {
            loop.map { (dx: $0.dx, dy: $0.dy, count: $0.count * factor) }
        }
        // The loops at the sizes this runner uses them: about 6, 6, 10 and 11 km.
        let options = [scaled(loops[0], 2), loops[2], scaled(loops[1], 3), loops[3]]
        var legs: [(dx: Int, dy: Int, count: Int)]
        if seed % 5 == 4 {
            let out = max(blocks / 2, 2)
            legs = [(1, 0, out), (-1, 0, out)]
        } else {
            let length = { (route: [(dx: Int, dy: Int, count: Int)]) in route.reduce(0) { $0 + $1.count } }
            let nearest = options.enumerated().min { lhs, rhs in
                let left = abs(length(lhs.element) - blocks) * 2 + (lhs.offset + seed) % 2
                let right = abs(length(rhs.element) - blocks) * 2 + (rhs.offset + seed) % 2
                return left < right
            }
            legs = nearest?.element ?? options[0]
            // A long run is the longest loop plus the favourite avenue out and back.
            let extra = (blocks - length(legs)) / 2
            if extra > 2 {
                legs += [(1, 0, extra), (-1, 0, extra)]
            }
            // Some days the same loop the other way round.
            if seed % 3 == 0 {
                legs = legs.reversed().map { (dx: -$0.dx, dy: -$0.dy, count: $0.count) }
            }
        }

        var lat = home.lat
        var lon = home.lon
        var points: [Coordinate] = []
        var step = 0
        func add() {
            // A few metres of GPS wander, the same for a given run every time.
            let jitter = 0.000_03
            let noiseLat = sin(Double(step * 12_989 + seed * 78_233)) * jitter
            let noiseLon = cos(Double(step * 39_346 + seed * 11_731)) * jitter
            points.append(Coordinate(CLLocationCoordinate2D(latitude: lat + noiseLat, longitude: lon + noiseLon)))
            step += 1
        }
        add()
        for leg in legs {
            for _ in 0..<leg.count {
                // A fix every 20 m, like a phone or Watch recording. The heatmap only joins
                // fixes under `RouteHeatmap.fillMeters` apart, so sparser fixes would draw as
                // lone dots with no ground covered.
                for _ in 0..<fixesPerBlock {
                    lat += Double(leg.dy) * block.lat / Double(fixesPerBlock)
                    lon += Double(leg.dx) * block.lon / Double(fixesPerBlock)
                    add()
                }
            }
        }
        return points
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

    // MARK: - Coach read

    /// The sample read for `--seed-coach-read`. It sits on the newest run, which is this
    /// week's long run (`weeksAgo` 0, index 3): 13.8 km at about 6:07/km with a route, a
    /// negative split from `splits(...)`, no heart rate, and the note "Felt strong
    /// through the second half." Last week's long run was 14.4 km and the four before
    /// this one average the same 6:07/km, so every figure below is one the run's own
    /// screens show. Change the seed's shape and this has to change with it.
    static func coachRead(metric: Bool) -> AICoachInsight {
        let distance = metric ? "13.8 km" : "8.6 mi"
        let distanceDelta = metric ? "-0.6 km" : "-0.4 mi"
        let pace = metric ? "6:07/km" : "9:51/mi"
        let backHalf = metric ? "11s/km" : "18s/mi"
        let nextLong = metric ? "14.5 km" : "9 miles"
        return AICoachInsight(
            headline: "Steady long run, strong finish",
            summary: "\(distance) at your usual long-run pace, and the back half was quicker "
                + "than the front. That's a long run doing its job.",
            fullAnalysis: """
                You held \(pace) for \(distance), the same pace as your last four long runs. \
                It was a little shorter than last week, which is fine in a week that also had \
                a tempo and an interval session.

                **The finish is the good part.** Your splits got quicker as you went, and the \
                second half was about \(backHalf) faster than the first. You wrote that you \
                felt strong late on, and the splits agree: you started easy enough to have \
                something left.

                - Keep starting long runs at this effort.
                - Add distance slowly, about 10% a week at most.
                """,
            confidence: 82,
            evidence: [
                AICoachEvidenceItem(label: "Distance", value: distance, delta: distanceDelta, tone: "brand"),
                AICoachEvidenceItem(label: "Avg pace", value: pace, delta: "Your usual", tone: "easy"),
                AICoachEvidenceItem(label: "Back half", value: backHalf, delta: "Quicker", tone: "easy")
            ],
            actionItems: [
                AICoachActionItem(
                    title: "Start the next long run the same way",
                    detail: "Easy for the first few miles, then let the pace come to you. "
                        + "That's what gave you a strong finish today.",
                    priority: "high",
                    metric: pace,
                    tone: "easy"
                ),
                AICoachActionItem(
                    title: "Keep tomorrow easy",
                    detail: "A rest day or a short, slow run lets the long run sink in.",
                    priority: "medium",
                    metric: nil,
                    tone: nil
                )
            ],
            focusAreas: ["Pacing", "Endurance"],
            nextWorkoutSuggestion: "Next week's long run can go to about \(nextLong) at the same easy effort.",
            nextWorkoutRationale: "You finished this one with something left, so a small step up is safe.",
            apiReady: true
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
