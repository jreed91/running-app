import Foundation

// MARK: - RouteSnapping

/// Moving a run's GPS line onto the streets it was run on, for the heatmap.
///
/// GPS sits 10–30 m off the road between houses, so a heatmap of raw routes runs through
/// back gardens. Snapping asks a router (Apple Maps walking directions, in the app) for
/// the way between points along the run and uses its line instead. This type is the
/// pure part: where to put the points, which pieces to ask for, whether an answer is
/// believable, and joining the answers up. Asking is ``RouteSnapper``'s job.
enum RouteSnapping {
    /// How far the GPS line may stray from the straight line between two kept points.
    /// Small enough that a turn at a corner gets a point of its own.
    static let toleranceMeters = 25.0
    /// The longest piece asked for in one go: a longer one could be routed round a
    /// different way than the run went.
    static let maxLegMeters = 600.0
    /// A piece shorter than this is drawn as run; asking costs more than it gains.
    static let minLegMeters = 40.0

    /// One piece of a run to ask the router for.
    struct Leg: Sendable, Equatable {
        var from: RouteHeatmap.Point
        var to: RouteHeatmap.Point
        /// The GPS line between the two, to fall back on and to judge the answer by.
        var gps: [RouteHeatmap.Point]

        /// Which piece of street this is, for asking once however many runs went along
        /// it: the cells at either end.
        var key: Key { Key(from: RouteHeatmap.cell(of: from), to: RouteHeatmap.cell(of: to)) }

        var gpsMeters: Double { RouteSnapping.length(gps) }
        var straightMeters: Double { RouteHeatmap.distance(from, to) }
        /// Whether it is worth asking the router about.
        var needsRouting: Bool { straightMeters >= RouteSnapping.minLegMeters }
    }

    struct Key: Hashable, Codable, Sendable {
        var from: RouteHeatmap.Cell
        var to: RouteHeatmap.Cell
    }

    /// The run's pieces, segment by segment: the GPS line cut at its turns (where it
    /// strays more than ``toleranceMeters`` from straight) and at least every
    /// ``maxLegMeters``.
    static func legs(of trace: RouteHeatmap.Trace) -> [[Leg]] {
        trace.segments.compactMap { segment -> [Leg]? in
            let points = segment.map { trace.centers[Int($0)] }
            guard points.count >= 2 else { return nil }
            let kept = keyPoints(points)
            return zip(kept, kept.dropFirst()).map { start, end in
                Leg(from: points[start], to: points[end], gps: Array(points[start...end]))
            }
        }
    }

    /// The indices of the points kept: the ends, every turn, and enough more that no
    /// piece is longer than ``maxLegMeters``.
    static func keyPoints(_ points: [RouteHeatmap.Point]) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var keep = Set([0, points.count - 1])
        // Douglas–Peucker, without recursion so a long run can't run out of stack.
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last - first > 1 else { continue }
            var farthest = first
            var farthestMeters = 0.0
            for index in (first + 1)..<last {
                let meters = offset(of: points[index], from: points[first], to: points[last])
                if meters > farthestMeters {
                    farthest = index
                    farthestMeters = meters
                }
            }
            if farthestMeters > toleranceMeters {
                keep.insert(farthest)
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        // Then cut anything too long, along the GPS line.
        var result: [Int] = []
        for index in keep.sorted() {
            if let previous = result.last {
                var meters = 0.0
                for step in (previous + 1)..<max(index, previous + 1) {
                    meters += RouteHeatmap.distance(points[step - 1], points[step])
                    if meters >= maxLegMeters, step < index {
                        result.append(step)
                        meters = 0
                    }
                }
            }
            result.append(index)
        }
        return result
    }

    /// Whether the router's line is the way the runner went: about as long as the GPS
    /// line, not a detour round a park the map has no path through, and ending near
    /// where the piece ends. Otherwise the GPS line is kept for that piece.
    static func accepts(_ routed: [RouteHeatmap.Point], for leg: Leg) -> Bool {
        guard let first = routed.first, let last = routed.last else { return false }
        let gps = leg.gpsMeters
        let meters = length(routed)
        guard meters <= gps * 1.3 + 60, meters >= gps * 0.6 - 30 else { return false }
        return RouteHeatmap.distance(first, leg.from) <= 60 && RouteHeatmap.distance(last, leg.to) <= 60
    }

    /// The snapped run: each piece's routed line where there is a believable one, its
    /// GPS line where not, joined in order. Segments stay apart, more than
    /// ``RouteHeatmap/gapMeters`` from each other, so ``RouteHeatmap/trace(_:)`` doesn't
    /// draw a line across a pause.
    static func snapped(_ legs: [[Leg]], routes: (Leg) -> [RouteHeatmap.Point]?) -> RouteHeatmap.Trace {
        var segments: [[RouteHeatmap.Point]] = []
        for segment in legs {
            var points: [RouteHeatmap.Point] = []
            for leg in segment {
                let line: [RouteHeatmap.Point]
                if let routed = routes(leg), accepts(routed, for: leg) {
                    line = routed
                } else {
                    line = leg.gps
                }
                // Each piece starts where the last ended.
                points += points.isEmpty ? line : Array(line.dropFirst())
            }
            if !points.isEmpty { segments.append(points) }
        }
        return RouteHeatmap.trace(segments: segments)
    }

    /// Metres along a line.
    static func length(_ points: [RouteHeatmap.Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + RouteHeatmap.distance($1.0, $1.1) }
    }

    /// How far `point` is from the straight line between `start` and `end`, in metres.
    static func offset(of point: RouteHeatmap.Point, from start: RouteHeatmap.Point, to end: RouteHeatmap.Point) -> Double {
        let scale = 111_320.0
        let cosine = cos(start.latitude * .pi / 180)
        let ax = 0.0, ay = 0.0
        let bx = (end.longitude - start.longitude) * scale * cosine
        let by = (end.latitude - start.latitude) * scale
        let px = (point.longitude - start.longitude) * scale * cosine
        let py = (point.latitude - start.latitude) * scale
        let lengthSquared = bx * bx + by * by
        guard lengthSquared > 0 else { return hypot(px - ax, py - ay) }
        let t = min(1, max(0, (px * bx + py * by) / lengthSquared))
        return hypot(px - t * bx, py - t * by)
    }
}

extension RouteHeatmap {
    /// A trace of several separate lines, never joined to each other.
    static func trace(segments lines: [[Point]]) -> Trace {
        var index: [Cell: Int32] = [:]
        var cells: [Cell] = []
        var centers: [Point] = []
        var segments: [[Int32]] = []
        for line in lines {
            let piece = trace(line)
            for segment in piece.segments {
                segments.append(segment.map { local in
                    let cell = piece.cells[Int(local)]
                    if let known = index[cell] { return known }
                    let global = Int32(cells.count)
                    index[cell] = global
                    cells.append(cell)
                    centers.append(piece.centers[Int(local)])
                    return global
                })
            }
        }
        return Trace(cells: cells, centers: centers, segments: segments)
    }
}
