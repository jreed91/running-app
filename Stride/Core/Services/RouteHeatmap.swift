import Foundation

// MARK: - RouteHeatmap

/// The personal heatmap: every route snapped to a fine grid, so the streets run most
/// often can be told apart from the ones run once.
///
/// The first heatmap drew each route as its own faint line and let the overlap do the
/// work. That read the routes on the main actor each time, kept only the newest 400,
/// and a street run 300 times was 300 polylines. Here each run becomes a ``Trace`` once
/// (the cells it passed through, in order), the traces are kept by ``RouteHeatmapCache``,
/// and ``build(_:)`` folds any set of them into a ``Heatmap``: one line per stretch of
/// street, coloured by how many runs used it.
///
/// Foundation only, so it can be tested anywhere.
enum RouteHeatmap {

    /// The side of a grid cell. Close enough that two streets a block apart never share a
    /// cell, loose enough that GPS wander on one street stays in one.
    static let cellMeters = 20.0

    /// A jump between two route points longer than this is a GPS gap or a paused run,
    /// not a street, so the line breaks there instead of cutting across the map.
    static let gapMeters = 250.0

    /// How many heat colours the map uses, coolest first.
    static let levels = 5

    private static let metersPerDegree = 111_320.0

    // MARK: Types

    /// A point on the map. Decodes the stored route blob as it is (`latitude`,
    /// `longitude`), so this file needs no CoreLocation.
    struct Point: Codable, Hashable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    /// One square of the grid.
    struct Cell: Codable, Hashable, Sendable, Comparable {
        var x: Int32
        var y: Int32

        static func < (lhs: Cell, rhs: Cell) -> Bool {
            lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
        }
    }

    /// One run's route on the grid: each cell it touched with where in that cell it went,
    /// and the order it went through them, broken at GPS gaps.
    struct Trace: Codable, Equatable, Sendable {
        /// Every cell touched, once, with the run's mean position inside it.
        var cells: [Cell]
        var centers: [Point]
        /// Stretches of the route as indexes into `cells`, in running order.
        var segments: [[Int32]]

        var isEmpty: Bool { cells.isEmpty }

        init(cells: [Cell], centers: [Point], segments: [[Int32]]) {
            self.cells = cells
            self.centers = centers
            self.segments = segments
        }

        // Stored packed: years of traces as JSON numbers were tens of megabytes.

        init(from decoder: Decoder) throws {
            let data = try decoder.singleValueContainer().decode(Data.self)
            guard let trace = Trace(packed: data) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad trace"))
            }
            self = trace
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(packed())
        }

        /// Each cell as its column, row and where in it the run went (to 1/65535 of a
        /// cell, a few millimetres), then each segment's cell indexes. Little-endian.
        func packed() -> Data {
            var data = Data(capacity: 8 + cells.count * 12 + segments.reduce(0) { $0 + 4 + $1.count * 4 })
            func put<T: FixedWidthInteger>(_ value: T) {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            put(UInt32(cells.count))
            for (cell, center) in zip(cells, centers) {
                let origin = RouteHeatmap.origin(of: cell)
                let height = RouteHeatmap.rowHeight
                let width = RouteHeatmap.columnWidth(row: Double(cell.y))
                put(cell.x)
                put(cell.y)
                put(Self.fraction((center.latitude - origin.latitude) / height))
                put(Self.fraction((center.longitude - origin.longitude) / width))
            }
            put(UInt32(segments.count))
            for segment in segments {
                put(UInt32(segment.count))
                for index in segment { put(index) }
            }
            return data
        }

        init?(packed data: Data) {
            var offset = data.startIndex
            func take<T: FixedWidthInteger>(_: T.Type) -> T? {
                let size = MemoryLayout<T>.size
                guard offset + size <= data.endIndex else { return nil }
                var value: T = 0
                withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<offset + size) }
                offset += size
                return T(littleEndian: value)
            }
            guard let cellCount = take(UInt32.self), Int(cellCount) * 12 <= data.count else { return nil }
            var cells: [Cell] = []
            var centers: [Point] = []
            cells.reserveCapacity(Int(cellCount))
            centers.reserveCapacity(Int(cellCount))
            for _ in 0..<cellCount {
                guard let x = take(Int32.self), let y = take(Int32.self),
                      let fy = take(UInt16.self), let fx = take(UInt16.self) else { return nil }
                let cell = Cell(x: x, y: y)
                let origin = RouteHeatmap.origin(of: cell)
                cells.append(cell)
                centers.append(Point(
                    latitude: origin.latitude + Double(fy) / 65_535 * RouteHeatmap.rowHeight,
                    longitude: origin.longitude + Double(fx) / 65_535 * RouteHeatmap.columnWidth(row: Double(y))
                ))
            }
            guard let segmentCount = take(UInt32.self) else { return nil }
            var segments: [[Int32]] = []
            for _ in 0..<segmentCount {
                guard let length = take(UInt32.self), Int(length) * 4 <= data.endIndex - offset else { return nil }
                var segment: [Int32] = []
                segment.reserveCapacity(Int(length))
                for _ in 0..<length {
                    guard let index = take(Int32.self), index >= 0, Int(index) < cells.count else { return nil }
                    segment.append(index)
                }
                segments.append(segment)
            }
            self.init(cells: cells, centers: centers, segments: segments)
        }

        private static func fraction(_ value: Double) -> UInt16 {
            UInt16((min(max(value, 0), 1) * 65_535).rounded())
        }
    }

    /// One stretch of street at one heat level, ready to draw.
    struct Line: Equatable, Sendable {
        /// 1 (run once) to ``RouteHeatmap/levels`` (run most).
        var level: Int
        var points: [Point]
    }

    /// What a set of runs adds up to on the map.
    struct Heatmap: Equatable, Sendable {
        /// Coolest first, so the hottest streets draw on top.
        var lines: [Line]
        /// Runs that had a route.
        var runCount: Int
        /// The most runs that went along any one stretch.
        var maxRuns: Int
        /// The length of ground covered, each stretch counted once however often it was run.
        var uniqueMeters: Double

        static let empty = Heatmap(lines: [], runCount: 0, maxRuns: 0, uniqueMeters: 0)
    }

    // MARK: Grid

    /// The cell a point falls in. Rows are a fixed height; each row's cells are as wide as
    /// `cellMeters` at that row's latitude, so cells stay square away from the equator.
    static func cell(of point: Point) -> Cell {
        let y = (point.latitude / rowHeight).rounded(.down)
        let x = (point.longitude / columnWidth(row: y)).rounded(.down)
        return Cell(x: Int32(clamping: Int(x)), y: Int32(clamping: Int(y)))
    }

    /// The height of a row, in degrees of latitude.
    static var rowHeight: Double { cellMeters / metersPerDegree }

    /// The width of a cell in row `y`, in degrees of longitude.
    static func columnWidth(row y: Double) -> Double {
        let rowLatitude = (y + 0.5) * rowHeight
        return rowHeight / max(cos(rowLatitude * .pi / 180), 0.01)
    }

    /// The south-west corner of a cell.
    static func origin(of cell: Cell) -> Point {
        Point(
            latitude: Double(cell.y) * rowHeight,
            longitude: Double(cell.x) * columnWidth(row: Double(cell.y))
        )
    }

    /// Metres between two points: flat-earth, which is exact enough across a few hundred metres.
    static func distance(_ a: Point, _ b: Point) -> Double {
        let meanLatitude = (a.latitude + b.latitude) / 2 * .pi / 180
        let dy = (b.latitude - a.latitude) * metersPerDegree
        let dx = (b.longitude - a.longitude) * metersPerDegree * cos(meanLatitude)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: Tracing a run

    /// The stored route blob (JSON of latitude/longitude pairs) as a trace. `nil` for a
    /// run with no route or one that can't be read.
    static func trace(routeData: Data) -> Trace? {
        guard !routeData.isEmpty, let points = try? JSONDecoder().decode([Point].self, from: routeData) else {
            return nil
        }
        return trace(points)
    }

    /// A route as the cells it passed through. Points are filled in between GPS fixes so a
    /// sparse route still touches every cell along the street.
    static func trace(_ points: [Point]) -> Trace {
        var index: [Cell: Int32] = [:]
        var cells: [Cell] = []
        var sums: [(latitude: Double, longitude: Double, count: Double)] = []
        var segments: [[Int32]] = []
        var segment: [Int32] = []

        func visit(_ point: Point) {
            let cell = cell(of: point)
            let i: Int32
            if let known = index[cell] {
                i = known
                sums[Int(i)].latitude += point.latitude
                sums[Int(i)].longitude += point.longitude
                sums[Int(i)].count += 1
            } else {
                i = Int32(cells.count)
                index[cell] = i
                cells.append(cell)
                sums.append((point.latitude, point.longitude, 1))
            }
            if segment.last != i { segment.append(i) }
        }

        func closeSegment() {
            if segment.count > 1 { segments.append(segment) }
            segment = []
        }

        var previous: Point?
        for point in points where isPlausible(point) {
            if let previous {
                let meters = distance(previous, point)
                if meters > gapMeters {
                    closeSegment()
                } else {
                    // A sample every half cell, so no cell along the way is skipped.
                    let steps = Int((meters / (cellMeters / 2)).rounded(.up))
                    if steps > 1 {
                        for step in 1..<steps {
                            let t = Double(step) / Double(steps)
                            visit(Point(
                                latitude: previous.latitude + (point.latitude - previous.latitude) * t,
                                longitude: previous.longitude + (point.longitude - previous.longitude) * t
                            ))
                        }
                    }
                }
            }
            visit(point)
            previous = point
        }
        closeSegment()

        // A cell only ever seen inside a dropped one-cell segment is noise.
        let used = Set(segments.joined())
        guard used.count != cells.count else {
            return Trace(cells: cells, centers: sums.map(center), segments: segments)
        }
        var remap: [Int32: Int32] = [:]
        var keptCells: [Cell] = []
        var keptCenters: [Point] = []
        for (i, cell) in cells.enumerated() where used.contains(Int32(i)) {
            remap[Int32(i)] = Int32(keptCells.count)
            keptCells.append(cell)
            keptCenters.append(center(sums[i]))
        }
        return Trace(
            cells: keptCells,
            centers: keptCenters,
            segments: segments.map { $0.compactMap { remap[$0] } }
        )
    }

    private static func center(_ sum: (latitude: Double, longitude: Double, count: Double)) -> Point {
        Point(latitude: sum.latitude / sum.count, longitude: sum.longitude / sum.count)
    }

    /// Drops the (0, 0) a lost fix sometimes records, and anything off the globe.
    private static func isPlausible(_ point: Point) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite
            && abs(point.latitude) <= 85 && abs(point.longitude) <= 180
            && !(point.latitude == 0 && point.longitude == 0)
    }

    // MARK: Building the map

    /// Two neighbouring cells a run went between, either way round.
    struct Edge: Hashable, Sendable {
        let a: Cell
        let b: Cell

        init(_ first: Cell, _ second: Cell) {
            if first < second { a = first; b = second } else { a = second; b = first }
        }
    }

    /// The heat level of a stretch run `runs` times when the busiest was run `maxRuns`
    /// times. Logarithmic, because a home street run 400 times would otherwise leave every
    /// other street in the coolest colour.
    static func level(runs: Int, maxRuns: Int) -> Int {
        guard runs > 0 else { return 0 }
        guard maxRuns > 1 else { return 1 }
        // A stretch run once is always the coolest colour, the busiest always the hottest.
        let share = log(Double(min(runs, maxRuns))) / log(Double(maxRuns))
        return min(levels, 1 + Int((share * Double(levels - 1)).rounded(.down)))
    }

    /// Every trace folded into one map. A run counts once on a stretch however many
    /// times it went along it, so an out-and-back is one run, not two.
    static func build(_ traces: [Trace]) -> Heatmap {
        var edgeRuns: [Edge: Int] = [:]
        var centerSums: [Cell: (latitude: Double, longitude: Double, count: Double)] = [:]
        var runCount = 0

        for trace in traces where !trace.isEmpty {
            var edges = Set<Edge>()
            for segment in trace.segments {
                for (from, to) in zip(segment, segment.dropFirst()) {
                    edges.insert(Edge(trace.cells[Int(from)], trace.cells[Int(to)]))
                }
            }
            guard !edges.isEmpty else { continue }
            runCount += 1
            for edge in edges { edgeRuns[edge, default: 0] += 1 }
            for (cell, center) in zip(trace.cells, trace.centers) {
                var sum = centerSums[cell] ?? (0, 0, 0)
                sum.latitude += center.latitude
                sum.longitude += center.longitude
                sum.count += 1
                centerSums[cell] = sum
            }
        }

        guard let maxRuns = edgeRuns.values.max() else { return .empty }
        let centers = centerSums.mapValues(center)

        var byLevel: [Int: [Edge]] = [:]
        var uniqueMeters = 0.0
        for (edge, runs) in edgeRuns {
            byLevel[level(runs: runs, maxRuns: maxRuns), default: []].append(edge)
            if let a = centers[edge.a], let b = centers[edge.b] { uniqueMeters += distance(a, b) }
        }

        var lines: [Line] = []
        for level in byLevel.keys.sorted() {
            for chain in chains(byLevel[level] ?? []) {
                let points = chain.compactMap { centers[$0] }
                if points.count > 1 { lines.append(Line(level: level, points: points)) }
            }
        }
        return Heatmap(lines: lines, runCount: runCount, maxRuns: maxRuns, uniqueMeters: uniqueMeters)
    }

    /// Edges joined into as few long paths as walking them allows: a path runs on through
    /// a cell with exactly two edges and stops at ends and junctions. Fewer, longer lines
    /// are much less work for the map than one line per edge.
    static func chains(_ edges: [Edge]) -> [[Cell]] {
        var neighbours: [Cell: [Cell]] = [:]
        for edge in edges {
            neighbours[edge.a, default: []].append(edge.b)
            neighbours[edge.b, default: []].append(edge.a)
        }
        for key in neighbours.keys { neighbours[key]?.sort() }

        var walked = Set<Edge>()
        var chains: [[Cell]] = []

        func walk(from start: Cell, to first: Cell) -> [Cell] {
            var chain = [start, first]
            walked.insert(Edge(start, first))
            var previous = start
            var current = first
            while let next = neighbours[current], next.count == 2 {
                let onward = next[0] == previous ? next[1] : next[0]
                let edge = Edge(current, onward)
                guard !walked.contains(edge) else { break }
                walked.insert(edge)
                chain.append(onward)
                previous = current
                current = onward
            }
            return chain
        }

        let nodes = neighbours.keys.sorted()
        // Ends and junctions first, so paths start where streets do.
        for node in nodes where neighbours[node]?.count != 2 {
            for neighbour in neighbours[node] ?? [] where !walked.contains(Edge(node, neighbour)) {
                chains.append(walk(from: node, to: neighbour))
            }
        }
        // Whatever is left is closed loops.
        for node in nodes {
            for neighbour in neighbours[node] ?? [] where !walked.contains(Edge(node, neighbour)) {
                chains.append(walk(from: node, to: neighbour))
            }
        }
        return chains
    }
}
