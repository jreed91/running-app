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

    /// The longest gap between two fixes filled with a straight line. A watch or phone
    /// records a fix every few metres; a longer gap means a lost signal or a sparse
    /// recording, and a straight line across it cut corners through gardens.
    static let fillMeters = 50.0

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

        /// The trace with the runner's private parts taken out: cells within
        /// `hideEndsMeters` of the start or finish (along the route) and cells near a
        /// private place. Segments split where cells were hidden, so nothing is drawn
        /// across a gap.
        func trimmed(_ privacy: Privacy) -> Trace {
            guard privacy.hidesAnything, !isEmpty else { return self }
            // How far along the route each step of each segment is.
            var along: [[Double]] = []
            var total = 0.0
            var previous: Point?
            for segment in segments {
                var distances: [Double] = []
                for index in segment {
                    let point = centers[Int(index)]
                    if let previous { total += RouteHeatmap.distance(previous, point) }
                    distances.append(total)
                    previous = point
                }
                along.append(distances)
            }
            let ends = max(0, privacy.hideEndsMeters)

            func isHidden(_ index: Int32, at distance: Double) -> Bool {
                if ends > 0, distance < ends || total - distance < ends { return true }
                let point = centers[Int(index)]
                // A cell's centre can sit up to a cell from where the run went.
                return privacy.zones.contains {
                    RouteHeatmap.distance($0.center, point) <= $0.radiusMeters + RouteHeatmap.cellMeters
                }
            }

            var kept: [[Int32]] = []
            for (segment, distances) in zip(segments, along) {
                var piece: [Int32] = []
                for (index, distance) in zip(segment, distances) {
                    if isHidden(index, at: distance) {
                        if piece.count > 1 { kept.append(piece) }
                        piece = []
                    } else {
                        piece.append(index)
                    }
                }
                if piece.count > 1 { kept.append(piece) }
            }

            var remap: [Int32: Int32] = [:]
            var keptCells: [Cell] = []
            var keptCenters: [Point] = []
            for index in kept.joined() where remap[index] == nil {
                remap[index] = Int32(keptCells.count)
                keptCells.append(cells[Int(index)])
                keptCenters.append(centers[Int(index)])
            }
            return Trace(
                cells: keptCells,
                centers: keptCenters,
                segments: kept.map { $0.compactMap { remap[$0] } }
            )
        }

        /// Whether the route went through any of `area`'s cells.
        func passes(through area: Set<Cell>) -> Bool {
            cells.contains { area.contains($0) }
        }

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

    /// One square of the map and how many runs went through it, ready to draw.
    struct HeatCell: Equatable, Sendable {
        /// Where the runs went inside the cell, on average.
        var center: Point
        var runs: Int
        /// 1 (run once) to ``RouteHeatmap/levels`` (run most).
        var level: Int
        /// Its square on the grid, when it came from runs' traces.
        var cell: Cell?
    }

    /// What a set of runs adds up to on the map.
    struct Heatmap: Equatable, Sendable {
        /// Every cell any run went through, coolest first, so the hottest draw on top.
        ///
        /// Cells rather than lines: GPS wanders a few metres either side of the street,
        /// so years of runs on one street are a band of neighbouring cells. Joining those
        /// into lines made a mesh of tens of thousands of tiny lines, which MapKit drew on
        /// every frame. Cells are drawn by a tiled renderer that only looks at the ones on
        /// screen, off the main thread.
        var cells: [HeatCell]
        /// Runs that had a route.
        var runCount: Int
        /// The most runs that went through any one cell.
        var maxRuns: Int
        /// The length of ground covered, each street counted once however often it was run.
        var uniqueMeters: Double
        /// Every step a run took from one square to the next, so the map joins only the
        /// squares a run went between, never two squares that just happen to be side by
        /// side (two runs' GPS a street's width apart).
        var edges: [Edge]
        /// Which build this is. Two maps are equal when they are the same build, so
        /// SwiftUI and the map view never compare every cell on the main actor.
        var id: UUID

        init(
            cells: [HeatCell],
            runCount: Int,
            maxRuns: Int,
            uniqueMeters: Double,
            edges: [Edge] = [],
            id: UUID = UUID()
        ) {
            self.cells = cells
            self.edges = edges
            self.runCount = runCount
            self.maxRuns = maxRuns
            self.uniqueMeters = uniqueMeters
            self.id = id
        }

        static func == (lhs: Heatmap, rhs: Heatmap) -> Bool { lhs.id == rhs.id }

        static let empty = Heatmap(
            cells: [], runCount: 0, maxRuns: 0, uniqueMeters: 0,
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        )

        var isEmpty: Bool { cells.isEmpty }
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

    /// Every cell within about `radiusMeters` of a point: a square of cells around the
    /// one it falls in. For "which runs went here?", where a tap is never exact.
    static func cells(around point: Point, radiusMeters: Double) -> Set<Cell> {
        let center = cell(of: point)
        let reach = max(0, Int((radiusMeters / cellMeters).rounded(.up)))
        var cells = Set<Cell>()
        for dy in -reach...reach {
            let y = Int(center.y) + dy
            // Rows differ in width a little, so find the centre column again in each row.
            let rowPoint = Point(latitude: (Double(y) + 0.5) * rowHeight, longitude: point.longitude)
            let column = Int(cell(of: rowPoint).x)
            for dx in -reach...reach {
                cells.insert(Cell(x: Int32(clamping: column + dx), y: Int32(clamping: y)))
            }
        }
        return cells
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
            if !segment.isEmpty { segments.append(segment) }
            segment = []
        }

        var previous: Point?
        for point in points where isPlausible(point) {
            if let previous {
                let meters = distance(previous, point)
                if meters > fillMeters {
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
        // A lone fix is a glitch on a run that otherwise has lines; on a sparse recording
        // (every fix alone) it is all there is, so it stays, if there are at least two.
        if segments.contains(where: { $0.count > 1 }) || segments.count < 2 {
            segments.removeAll { $0.count < 2 }
        }

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

    /// The heat level of a cell run `runs` times when the busiest was run `maxRuns` times.
    /// Logarithmic, because a home street run 400 times would otherwise leave every other
    /// street in the coolest colour.
    static func level(runs: Int, maxRuns: Int) -> Int {
        guard runs > 0 else { return 0 }
        guard maxRuns > 1 else { return 1 }
        // A cell run once is always the coolest colour, the busiest always the hottest.
        let share = log(Double(min(runs, maxRuns))) / log(Double(maxRuns))
        return min(levels, 1 + Int((share * Double(levels - 1)).rounded(.down)))
    }

    /// Every trace folded into one map. A run counts once in a cell however many times it
    /// went through it, so an out-and-back is one run, not two.
    static func build(_ traces: [Trace]) -> Heatmap {
        var cellRuns: [Cell: Int] = [:]
        var centerSums: [Cell: (latitude: Double, longitude: Double, count: Double)] = [:]
        var runCount = 0
        var edges = Set<Edge>()

        for trace in traces where !trace.isEmpty && !trace.segments.isEmpty {
            runCount += 1
            edges.formUnion(self.edges(of: trace))
            // `cells` holds each cell of the trace once already.
            for (cell, center) in zip(trace.cells, trace.centers) {
                cellRuns[cell, default: 0] += 1
                var sum = centerSums[cell] ?? (0, 0, 0)
                sum.latitude += center.latitude
                sum.longitude += center.longitude
                sum.count += 1
                centerSums[cell] = sum
            }
        }
        guard let maxRuns = cellRuns.values.max() else { return .empty }

        let cells = cellRuns
            .compactMap { cell, runs -> HeatCell? in
                guard let sum = centerSums[cell] else { return nil }
                return HeatCell(center: center(sum), runs: runs, level: level(runs: runs, maxRuns: maxRuns), cell: cell)
            }
            .sorted { first, second in
                // Fewest runs first; ties in a fixed order so a rebuild draws the same.
                guard first.runs == second.runs else { return first.runs < second.runs }
                return (first.center.latitude, first.center.longitude) < (second.center.latitude, second.center.longitude)
            }
        return Heatmap(
            cells: cells,
            runCount: runCount,
            maxRuns: maxRuns,
            uniqueMeters: groundMeters(traces),
            edges: Array(edges)
        )
    }

    /// The length of street the traces cover, each street once.
    ///
    /// GPS wanders a cell either side of the street, so a street run often is a band of
    /// cells, and counting cells (or steps between them) counts it again on every run.
    /// Instead a run's steps count only where no earlier run went within a cell; a run's
    /// own cells are added to what's known once it is done, so a run counts in full, and a
    /// step into a cell it already went through this run (the way back of an
    /// out-and-back) doesn't count again.
    static func groundMeters(_ traces: [Trace], alreadyKnown: Set<Cell> = []) -> Double {
        var known = alreadyKnown
        var meters = 0.0
        for trace in traces where !trace.isEmpty {
            var visited = Set<Int32>()
            for segment in trace.segments {
                if let first = segment.first { visited.insert(first) }
                for (from, to) in zip(segment, segment.dropFirst()) {
                    defer { visited.insert(to) }
                    guard !visited.contains(to), !known.contains(trace.cells[Int(to)]) else { continue }
                    meters += distance(trace.centers[Int(from)], trace.centers[Int(to)])
                }
            }
            for cell in trace.cells { known.formUnion(neighbourhood(of: cell)) }
        }
        return meters
    }

    // MARK: Privacy

    /// What a shared heatmap leaves out, from the runner's ``RoutePrivacy``: the first and
    /// last stretch of every run, and anything near a private place.
    struct Privacy: Sendable, Equatable {
        struct Zone: Sendable, Equatable {
            var center: Point
            var radiusMeters: Double
        }

        var hideEndsMeters: Double
        var zones: [Zone]

        static let off = Privacy(hideEndsMeters: 0, zones: [])

        var hidesAnything: Bool { hideEndsMeters > 0 || !zones.isEmpty }
    }

    // MARK: New ground

    /// Streets run for the first time in a period.
    struct NewGround: Equatable, Sendable {
        /// The new cells' centres.
        var cells: [Point]
        /// Length of the new streets.
        var meters: Double
        /// Which result this is; equal only to itself, like ``Heatmap``.
        var id = UUID()

        static func == (lhs: NewGround, rhs: NewGround) -> Bool { lhs.id == rhs.id }

        static let none = NewGround(cells: [], meters: 0, id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
    }

    /// The cells the period's runs went through that no earlier run came within a cell
    /// of: where the period broke new ground. "Within a cell" so GPS wander on a familiar
    /// street doesn't show up as new.
    static func newGround(in traces: [Trace], before earlier: [Trace]) -> NewGround {
        var known = Set<Cell>()
        for trace in earlier {
            for cell in trace.cells { known.formUnion(neighbourhood(of: cell)) }
        }
        var fresh: [Cell: (latitude: Double, longitude: Double, count: Double)] = [:]
        for trace in traces {
            for (cell, center) in zip(trace.cells, trace.centers) where !known.contains(cell) {
                var sum = fresh[cell] ?? (0, 0, 0)
                sum.latitude += center.latitude
                sum.longitude += center.longitude
                sum.count += 1
                fresh[cell] = sum
            }
        }
        guard !fresh.isEmpty else { return .none }
        // Ground over the period's runs, starting from what the earlier runs knew.
        let meters = groundMeters(traces, alreadyKnown: known)
        return NewGround(cells: fresh.values.map(center), meters: meters)
    }

    /// A cell and its eight neighbours.
    static func neighbourhood(of cell: Cell) -> [Cell] {
        var cells: [Cell] = []
        cells.reserveCapacity(9)
        for dy in -1...1 {
            for dx in -1...1 {
                cells.append(Cell(x: cell.x &+ Int32(dx), y: cell.y &+ Int32(dy)))
            }
        }
        return cells
    }

    /// Every pair of neighbouring cells a trace went between.
    static func edges(of trace: Trace) -> Set<Edge> {
        var edges = Set<Edge>()
        for segment in trace.segments {
            for (from, to) in zip(segment, segment.dropFirst()) {
                edges.insert(Edge(trace.cells[Int(from)], trace.cells[Int(to)]))
            }
        }
        return edges
    }
}
