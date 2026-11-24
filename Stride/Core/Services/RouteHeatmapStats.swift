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
    static let statWindowMeters = 100.0
    /// Heart rate is averaged over this many seconds either side of a spot: a beat-to-beat
    /// reading jumps around more than the effort does.
    static let heartRateWindowSeconds = 15.0
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
                    values[Stat.heartRate.rawValue] = sample(
                        heartRate,
                        at: timeline.time(at: along) / durationSeconds,
                        within: heartRateWindowSeconds / durationSeconds
                    )
                }
            } else if hasHeartRate {
                values[Stat.heartRate.rawValue] = sample(
                    heartRate,
                    at: share,
                    within: heartRateWindowSeconds / max(durationSeconds, 1)
                )
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

    /// The believable samples from `share - within` to `share + within` of the way through,
    /// averaged; `nil` if there are none.
    private static func sample(_ samples: [Double], at share: Double, within: Double) -> Double? {
        guard !samples.isEmpty, share.isFinite, within.isFinite else { return nil }
        let count = Double(samples.count)
        let first = min(samples.count - 1, max(0, Int((share - within) * count)))
        let last = min(samples.count - 1, max(first, Int((share + within) * count)))
        let believable = samples[first...last].filter { plausibleHeartRate.contains($0) }
        guard !believable.isEmpty else { return nil }
        return believable.reduce(0, +) / Double(believable.count)
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

    /// A stat across many runs: each cell's average, smoothed along the street, coloured
    /// from cool to hot.
    struct StatMap: Equatable, Sendable {
        /// The cells, drawn like the heatmap's. `runs` is how many runs had a reading there.
        var heatmap: Heatmap
        var stat: Stat
        /// The coolest and hottest colours' values, for the legend: the 5th and 95th
        /// percentile of the cells, so one odd cell doesn't stretch the scale.
        var low: Double
        var high: Double
        /// Each cell's colour level, to colour the heatmap's own lines with.
        var levels: [Cell: Int] = [:]

        static func == (lhs: StatMap, rhs: StatMap) -> Bool { lhs.heatmap == rhs.heatmap }

        var isEmpty: Bool { heatmap.isEmpty }

        /// The run heatmap's own squares and lines, each coloured by this stat, so the stat
        /// follows the same streets, positions and joins as the heatmap. Squares with no
        /// reading are left out, with their lines.
        func colouring(_ base: Heatmap) -> Heatmap {
            var kept = Set<Cell>()
            var cells: [HeatCell] = []
            for heat in base.cells {
                guard let cell = heat.cell, let level = levels[cell] else { continue }
                kept.insert(cell)
                cells.append(HeatCell(center: heat.center, runs: heat.runs, level: level, cell: cell))
            }
            // Coolest first, so the hottest draw on top; ties in a fixed order.
            cells.sort { first, second in
                guard first.level == second.level else { return first.level < second.level }
                return (first.center.latitude, first.center.longitude) < (second.center.latitude, second.center.longitude)
            }
            return Heatmap(
                cells: cells,
                runCount: heatmap.runCount,
                maxRuns: heatmap.maxRuns,
                uniqueMeters: base.uniqueMeters,
                edges: base.edges.filter { kept.contains($0.a) && kept.contains($0.b) }
            )
        }
    }

    /// How many cells either way a cell's value is blended with, so one slow crossing or
    /// one spike doesn't make a block of its own colour: about 40 m.
    static let statSmoothingCells: Int32 = 2

    /// Each cell's stat averaged over the runs that had a reading there, each run once,
    /// then blended with the cells around it. Colours run evenly from the 5th to the 95th
    /// percentile, so a small difference stays a small difference in colour.
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
        let reach = statSmoothingCells
        var smoothed: [Cell: Double] = [:]
        for cell in sums.keys {
            var total = 0.0
            var weight = 0.0
            for dy in -reach...reach {
                for dx in -reach...reach {
                    guard let near = sums[Cell(x: cell.x &+ dx, y: cell.y &+ dy)] else { continue }
                    let w = Double(near.runs) / Double(1 + dx * dx + dy * dy)
                    total += near.value / Double(near.runs) * w
                    weight += w
                }
            }
            smoothed[cell] = total / weight
        }
        let values = smoothed.values.sorted()
        func percentile(_ share: Double) -> Double {
            values[min(values.count - 1, Int(share * Double(values.count - 1)))]
        }
        let bottom = percentile(0.05)
        let top = percentile(0.95)
        func level(_ value: Double) -> Int {
            guard top > bottom else { return 3 }
            var share = (value - bottom) / (top - bottom)
            if !stat.higherIsHotter { share = 1 - share }
            return min(levels, max(1, 1 + Int((min(max(share, 0), 1) * Double(levels)).rounded(.down))))
        }
        var cellLevels: [Cell: Int] = [:]
        var cells: [HeatCell] = []
        for (cell, value) in smoothed {
            let cellLevel = level(value)
            cellLevels[cell] = cellLevel
            cells.append(HeatCell(center: center(of: cell), runs: sums[cell]?.runs ?? 0, level: cellLevel, cell: cell))
        }
        cells.sort { first, second in
            guard first.level == second.level else { return first.level < second.level }
            return first.cell.map { cell in second.cell.map { cell < $0 } ?? true } ?? false
        }
        return StatMap(
            heatmap: Heatmap(
                cells: cells,
                runCount: runCount,
                maxRuns: sums.values.map(\.runs).max() ?? 0,
                uniqueMeters: 0
            ),
            stat: stat,
            low: stat.higherIsHotter ? bottom : top,
            high: stat.higherIsHotter ? top : bottom,
            levels: cellLevels
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
