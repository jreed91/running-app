import Foundation

// MARK: - BestEfforts

/// The fastest 400 m, 1K, mile, 5K, 10K, half and marathon inside each run, and the
/// records across all of them.
///
/// Stride's personal records used to count whole runs only (`ProgressStatsService
/// .personalRecordRun`): a fast first 5K inside a 12K long run never showed up. Every run
/// recorded or imported since the distance series was stored (`RunWorkout.distanceSeries`,
/// a reading every 10 m) carries enough to find the quickest stretch of any length, the
/// way runners expect from a running log.
///
/// Pure and `Sendable`, and it takes ``Sample``s rather than the tracker's own point type
/// so it can be tested without the rest of the app.
enum BestEfforts {

    // MARK: Distances

    enum Distance: String, CaseIterable, Sendable, Codable, Comparable {
        case fourHundred
        case oneK
        case mile
        case fiveK
        case tenK
        case half
        case marathon

        var meters: Double {
            switch self {
            case .fourHundred: return 400
            case .oneK: return 1_000
            case .mile: return 1_609.344
            case .fiveK: return 5_000
            case .tenK: return 10_000
            case .half: return 21_097.5
            case .marathon: return 42_195
            }
        }

        /// The fastest believable average speed over this distance, in metres per second:
        /// just above the men's world record. Anything quicker is a GPS jump, not a run,
        /// and would otherwise sit at the top of the records for good.
        var fastestPlausibleSpeed: Double {
            switch self {
            case .fourHundred: return 9.4   // WR 43.03 s ≈ 9.30 m/s
            case .oneK: return 7.7          // WR 2:11.96 ≈ 7.58 m/s
            case .mile: return 7.3          // WR 3:43.13 ≈ 7.21 m/s
            case .fiveK: return 6.7         // WR 12:35 ≈ 6.62 m/s
            case .tenK: return 6.4          // WR 26:11 ≈ 6.37 m/s
            case .half: return 6.2          // WR 57:30 ≈ 6.12 m/s
            case .marathon: return 5.9      // WR 2:00:35 ≈ 5.83 m/s
            }
        }

        static func < (lhs: Distance, rhs: Distance) -> Bool { lhs.meters < rhs.meters }
    }

    /// One cumulative distance reading.
    struct Sample: Equatable, Sendable {
        let elapsedSeconds: Double
        let meters: Double
    }

    // MARK: One run

    /// The quickest stretch of each distance the run covered, in seconds.
    ///
    /// Each window starts at a reading and ends where the cumulative distance first
    /// reaches the target, interpolated between the two readings either side, so a 10 m
    /// reading interval costs at most a reading's worth of time. Readings that go
    /// backwards in time or distance are dropped, no effort spans a GPS jump, and
    /// efforts faster than ``Distance/fastestPlausibleSpeed`` are discarded.
    static func efforts(in samples: [Sample]) -> [Distance: Double] {
        let stretches = pieces(of: cleaned(samples))
        let longest = stretches.map { ($0.last?.meters ?? 0) - ($0.first?.meters ?? 0) }.max() ?? 0
        guard longest > 0 else { return [:] }

        var result: [Distance: Double] = [:]
        for distance in Distance.allCases where distance.meters <= longest + 0.5 {
            let quickest = stretches.compactMap {
                fastest(distance.meters, in: $0, fastestSpeed: distance.fastestPlausibleSpeed)
            }.min()
            if let quickest { result[distance] = quickest }
        }
        return result
    }

    /// Faster than anyone has ever sprinted, between two readings: a GPS jump.
    static let jumpSpeed = 12.5

    /// Readings in order, from a zero start, each strictly later and no shorter than the
    /// one before.
    private static func cleaned(_ samples: [Sample]) -> [Sample] {
        var points: [Sample] = [Sample(elapsedSeconds: 0, meters: 0)]
        for sample in samples.sorted(by: { $0.elapsedSeconds < $1.elapsedSeconds }) {
            guard sample.elapsedSeconds.isFinite, sample.meters.isFinite,
                  let last = points.last,
                  sample.elapsedSeconds > last.elapsedSeconds,
                  sample.meters >= last.meters else { continue }
            points.append(sample)
        }
        return points
    }

    /// The readings cut wherever two in a row imply a GPS jump, so no effort can span
    /// one. The stretch the jump claims is lost rather than counted at an impossible
    /// speed or, worse, blended into a believable-looking record either side of it.
    private static func pieces(of points: [Sample]) -> [[Sample]] {
        var result: [[Sample]] = []
        var current: [Sample] = []
        for point in points {
            if let last = current.last {
                let speed = (point.meters - last.meters) / (point.elapsedSeconds - last.elapsedSeconds)
                if speed > jumpSpeed {
                    result.append(current)
                    current = []
                }
            }
            current.append(point)
        }
        result.append(current)
        return result.filter { $0.count > 1 }
    }

    /// The shortest time over `target` metres, by a sliding window.
    /// Windows quicker than `fastestSpeed` are skipped as GPS error.
    private static func fastest(_ target: Double, in points: [Sample], fastestSpeed: Double) -> Double? {
        var best: Double?
        var end = 1
        for start in points.indices {
            let goal = points[start].meters + target
            if end <= start { end = start + 1 }
            while end < points.count, points[end].meters < goal - 0.000_1 { end += 1 }
            guard end < points.count else { break }
            let before = points[end - 1]
            let after = points[end]
            let span = after.meters - before.meters
            let fraction = span > 0 ? (goal - before.meters) / span : 1
            let finish = before.elapsedSeconds + fraction * (after.elapsedSeconds - before.elapsedSeconds)
            let seconds = finish - points[start].elapsedSeconds
            guard seconds > 0, target / seconds <= fastestSpeed else { continue }
            if best.map({ seconds < $0 }) ?? true { best = seconds }
        }
        return best
    }

    // MARK: Across runs

    /// One run's best efforts.
    struct RunEfforts: Equatable, Sendable, Identifiable {
        let id: UUID
        let date: Date
        let efforts: [Distance: Double]
    }

    /// One effort, placed in time.
    struct Effort: Equatable, Sendable, Identifiable {
        let runID: UUID
        let date: Date
        let seconds: Double

        var id: UUID { runID }
    }

    /// Every run's effort at `distance`, quickest first. Ties go to the earlier run, which
    /// set the mark first.
    static func ranked(_ distance: Distance, in runs: [RunEfforts]) -> [Effort] {
        runs.compactMap { run in
            run.efforts[distance].map { Effort(runID: run.id, date: run.date, seconds: $0) }
        }
        .sorted { lhs, rhs in
            lhs.seconds == rhs.seconds ? lhs.date < rhs.date : lhs.seconds < rhs.seconds
        }
    }

    /// The all-time record at each distance anyone has run.
    static func records(in runs: [RunEfforts]) -> [Distance: Effort] {
        var result: [Distance: Effort] = [:]
        for distance in Distance.allCases {
            if let best = ranked(distance, in: runs).first { result[distance] = best }
        }
        return result
    }

    /// The efforts that set a new record when they were run, oldest first: the record's
    /// history, drawn as a falling step line.
    static func progression(_ distance: Distance, in runs: [RunEfforts]) -> [Effort] {
        var steps: [Effort] = []
        let inOrder = runs.sorted { $0.date < $1.date }
        for run in inOrder {
            guard let seconds = run.efforts[distance] else { continue }
            if steps.last.map({ seconds < $0.seconds }) ?? true {
                steps.append(Effort(runID: run.id, date: run.date, seconds: seconds))
            }
        }
        return steps
    }

    /// Where a run's effort sits among every run's at `distance`, 1 for the record, or
    /// `nil` when the run has no effort there.
    static func rank(of runID: UUID, _ distance: Distance, in runs: [RunEfforts]) -> Int? {
        ranked(distance, in: runs).firstIndex { $0.runID == runID }.map { $0 + 1 }
    }
}
