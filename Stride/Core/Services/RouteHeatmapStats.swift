import Foundation

// MARK: - HeatmapLayer

/// What the full-screen heatmap colours the streets by: how often you run them (the
/// heatmap), or how you run them there.
enum HeatmapLayer: String, CaseIterable, Identifiable, Sendable {
    case runs
    case heartRate
    case pace
    case hills

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runs: return String(localized: "Runs")
        case .heartRate: return String(localized: "Heart rate")
        case .pace: return String(localized: "Pace")
        case .hills: return String(localized: "Hills")
        }
    }

    /// The stat this layer shows, or `nil` for the run-count heatmap.
    var stat: RouteHeatmap.Stat? {
        switch self {
        case .runs: return nil
        case .heartRate: return .heartRate
        case .pace: return .pace
        case .hills: return .grade
        }
    }
}

// MARK: - Stats along a route

extension RouteHeatmap {
    /// A number measured along a run, placed on the streets where it was measured.
    enum Stat: Int, CaseIterable, Sendable {
        /// Beats per minute.
        case heartRate
        /// Seconds per kilometre. Faster is hotter.
        case pace
        /// How steep, in percent, uphill or downhill alike: an out-and-back would
        /// otherwise cancel its own hill out.
        case grade

        /// Whether a bigger number is the hotter colour.
        var higherIsHotter: Bool { self != .pace }
    }

    /// One run's heart rate, pace and steepness averaged in each cell it went through.
    /// ``none`` where the run had no reading of that stat. Every stat is zero or more, so
    /// a negative number can mean "none" and still store in a property list, which NaN
    /// can't be trusted to.
    struct RunStats: Codable, Equatable, Sendable {
        var cells: [Cell]
        var heartRate: [Float]
        var pace: [Float]
        var grade: [Float]

        var isEmpty: Bool { cells.isEmpty }

        func values(_ stat: Stat) -> [Float] {
            switch stat {
            case .heartRate: return heartRate
            case .pace: return pace
            case .grade: return grade
            }
        }

        static let empty = RunStats(cells: [], heartRate: [], pace: [], grade: [])
        static let none: Float = -1
    }

    /// Metres between the readings taken along a route.
    static let statStepMeters = 10.0
    /// Pace and steepness are measured over this much road either side of a spot, so GPS
    /// noise on one fix doesn't make a sprint or a cliff.
    static let statWindowMeters = 50.0
    /// Paces outside this are standing still or a GPS jump, like ``TrendSeries``.
    static let plausiblePace = 150.0...1200.0
    static let plausibleHeartRate = 70.0...230.0
    static let maxGrade = 30.0

    /// Where along the route each reading was taken.
    ///
    /// The route has no clock, so a spot's time comes from how far along the route it is:
    /// its share of the route's length is the same share of the distance series, which
    /// has times (and altitudes, when the source had them). Without a series, time is
    /// spread evenly over the run, so heart rate still lands roughly where it was, but
    /// pace and hills are left out rather than made up. Heart-rate samples are taken as
    /// evenly spread over the run, which is how Health records them during a workout.
    static func stats(
        route: [Point],
        series: [SplitBucketing.DistancePoint],
        heartRate: [Double],
        durationSeconds: Double
    ) -> RunStats {
        let spots = walk(route)
        guard let routeLength = spots.last?.meters, routeLength > 0 else { return .empty }
        let timeline = Timeline(series)
        let hasHeartRate = !heartRate.isEmpty && durationSeconds > 0

        var index: [Cell: Int] = [:]
        var cells: [Cell] = []
        var sums: [[Double]] = []
        var counts: [[Int]] = []

        for spot in spots {
            let share = spot.meters / routeLength
            var values: [Double?] = [nil, nil, nil]
            if let timeline {
                let along = share * timeline.length
                values[Stat.pace.rawValue] = timeline.pace(at: along)
                values[Stat.grade.rawValue] = timeline.grade(at: along)
                if hasHeartRate {
                    values[Stat.heartRate.rawValue] = sample(heartRate, at: timeline.time(at: along) / durationSeconds)
                }
            } else if hasHeartRate {
                values[Stat.heartRate.rawValue] = sample(heartRate, at: share)
            }
            guard values.contains(where: { $0 != nil }) else { continue }
            let cell = cell(of: spot.point)
            let i: Int
            if let known = index[cell] {
                i = known
            } else {
                i = cells.count
                index[cell] = i
                cells.append(cell)
                sums.append([0, 0, 0])
                counts.append([0, 0, 0])
            }
            for (stat, value) in values.enumerated() {
                guard let value else { continue }
                sums[i][stat] += value
                counts[i][stat] += 1
            }
        }

        func column(_ stat: Stat) -> [Float] {
            cells.indices.map { i in
                counts[i][stat.rawValue] > 0 ? Float(sums[i][stat.rawValue] / Double(counts[i][stat.rawValue])) : RunStats.none
            }
        }
        return RunStats(cells: cells, heartRate: column(.heartRate), pace: column(.pace), grade: column(.grade))
    }

    /// Points every ``statStepMeters`` along the route, with how far along each is. A jump
    /// longer than ``fillMeters`` (a pause, lost signal) isn't filled in, but its length
    /// still counts, as it does in the distance series.
    static func walk(_ route: [Point]) -> [(point: Point, meters: Double)] {
        var spots: [(point: Point, meters: Double)] = []
        var meters = 0.0
        var previous: Point?
        for point in route {
            if let previous {
                let step = distance(previous, point)
                if step <= fillMeters, step > statStepMeters {
                    let pieces = Int((step / statStepMeters).rounded(.up))
                    for piece in 1..<pieces {
                        let t = Double(piece) / Double(pieces)
                        spots.append((
                            Point(
                                latitude: previous.latitude + (point.latitude - previous.latitude) * t,
                                longitude: previous.longitude + (point.longitude - previous.longitude) * t
                            ),
                            meters + step * t
                        ))
                    }
                }
                meters += step
            }
            spots.append((point, meters))
            previous = point
        }
        return spots
    }

    /// The sample `share` of the way through, or `nil` if it isn't a believable heart rate.
    private static func sample(_ samples: [Double], at share: Double) -> Double? {
        guard !samples.isEmpty, share.isFinite else { return nil }
        let i = min(samples.count - 1, max(0, Int(share * Double(samples.count))))
        let value = samples[i]
        return plausibleHeartRate.contains(value) ? value : nil
    }

    /// A run's distance series, asked for time, pace and altitude at a distance.
    struct Timeline {
        let meters: [Double]
        let seconds: [Double]
        /// Distance and altitude of the readings that have one.
        let altitudes: [(meters: Double, altitude: Double)]

        var length: Double { meters.last ?? 0 }

        init?(_ series: [SplitBucketing.DistancePoint]) {
            // Readings in order of distance, each further along than the last.
            var meters: [Double] = []
            var seconds: [Double] = []
            var altitudes: [(meters: Double, altitude: Double)] = []
            for point in series.sorted(by: { $0.elapsedSeconds < $1.elapsedSeconds }) {
                guard point.cumulativeMeters.isFinite, point.elapsedSeconds.isFinite else { continue }
                if let last = meters.last, point.cumulativeMeters <= last { continue }
                meters.append(point.cumulativeMeters)
                seconds.append(point.elapsedSeconds)
                if let altitude = point.altitudeMeters, altitude.isFinite {
                    altitudes.append((point.cumulativeMeters, altitude))
                }
            }
            guard meters.count >= 2, let last = meters.last, last > 0 else { return nil }
            self.meters = meters
            self.seconds = seconds
            self.altitudes = altitudes
        }

        func time(at distance: Double) -> Double {
            Self.interpolate(meters, seconds, at: distance)
        }

        /// Seconds per kilometre over the road either side of `distance`.
        func pace(at distance: Double) -> Double? {
            let (from, to) = window(around: distance)
            guard to - from > 1 else { return nil }
            let pace = (time(at: to) - time(at: from)) / (to - from) * 1000
            return RouteHeatmap.plausiblePace.contains(pace) ? pace : nil
        }

        /// How steep the road either side of `distance` is, in percent.
        func grade(at distance: Double) -> Double? {
            guard altitudes.count >= 2 else { return nil }
            let (from, to) = window(around: distance)
            guard to - from > 1 else { return nil }
            let xs = altitudes.map(\.meters)
            let ys = altitudes.map(\.altitude)
            let rise = Self.interpolate(xs, ys, at: to) - Self.interpolate(xs, ys, at: from)
            return min(abs(rise / (to - from) * 100), RouteHeatmap.maxGrade)
        }

        private func window(around distance: Double) -> (Double, Double) {
            let half = RouteHeatmap.statWindowMeters
            return (max(0, distance - half), min(length, distance + half))
        }

        /// Straight-line between the two readings either side of `x`; held flat past the ends.
        static func interpolate(_ xs: [Double], _ ys: [Double], at x: Double) -> Double {
            guard let first = xs.first, let last = xs.last else { return 0 }
            if x <= first { return ys[0] }
            if x >= last { return ys[ys.count - 1] }
            // The first reading past `x`.
            var low = 0
            var high = xs.count - 1
            while low < high {
                let mid = (low + high) / 2
                if xs[mid] <= x { low = mid + 1 } else { high = mid }
            }
            let x0 = xs[low - 1], x1 = xs[low]
            let t = x1 > x0 ? (x - x0) / (x1 - x0) : 0
            return ys[low - 1] + (ys[low] - ys[low - 1]) * t
        }
    }

    // MARK: The stat map

    /// A stat across many runs: each cell's average, coloured from cool to hot.
    struct StatMap: Equatable, Sendable {
        /// The cells, drawn like the heatmap's. `runs` is how many runs had a reading there.
        var heatmap: Heatmap
        var stat: Stat
        /// The coolest and hottest colours' values, for the legend: the 5th and 95th
        /// percentile of the cells, so one odd cell doesn't stretch the scale.
        var low: Double
        var high: Double

        static func == (lhs: StatMap, rhs: StatMap) -> Bool { lhs.heatmap == rhs.heatmap }

        var isEmpty: Bool { heatmap.isEmpty }
    }

    /// Each cell's stat averaged over the runs that had a reading there, each run once.
    /// The levels split the cells into five equal groups, so the colours spread over the
    /// whole map whatever the numbers are; a pace map in summer and in winter both use
    /// every colour.
    static func statMap(_ runs: [RunStats], stat: Stat) -> StatMap {
        var sums: [Cell: (value: Double, runs: Int)] = [:]
        var runCount = 0
        for run in runs {
            let values = run.values(stat)
            var counted = false
            for (cell, value) in zip(run.cells, values) where value >= 0 {
                var sum = sums[cell] ?? (0, 0)
                sum.value += Double(value)
                sum.runs += 1
                sums[cell] = sum
                counted = true
            }
            if counted { runCount += 1 }
        }
        guard !sums.isEmpty else {
            return StatMap(heatmap: .empty, stat: stat, low: 0, high: 0)
        }
        let averages = sums.map { (cell: $0.key, value: $0.value.value / Double($0.value.runs), runs: $0.value.runs) }
        // Coolest first.
        let sorted = averages.sorted { first, second in
            if first.value != second.value {
                return stat.higherIsHotter ? first.value < second.value : first.value > second.value
            }
            return first.cell < second.cell
        }
        let values = sorted.map(\.value)
        func percentile(_ share: Double) -> Double {
            values[min(values.count - 1, Int(share * Double(values.count - 1)))]
        }
        let cells = sorted.enumerated().map { position, entry in
            HeatCell(
                center: center(of: entry.cell),
                runs: entry.runs,
                level: min(levels, 1 + position * levels / sorted.count),
                cell: entry.cell
            )
        }
        return StatMap(
            heatmap: Heatmap(
                cells: cells,
                runCount: runCount,
                maxRuns: sums.values.map(\.runs).max() ?? 0,
                uniqueMeters: 0
            ),
            stat: stat,
            low: percentile(0.05),
            high: percentile(0.95)
        )
    }

    /// The middle of a cell.
    static func center(of cell: Cell) -> Point {
        let origin = origin(of: cell)
        return Point(
            latitude: origin.latitude + rowHeight / 2,
            longitude: origin.longitude + columnWidth(row: Double(cell.y)) / 2
        )
    }
}
