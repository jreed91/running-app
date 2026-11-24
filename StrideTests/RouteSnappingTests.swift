import Foundation
import Testing
@testable import Stride

struct RouteSnappingTests {
    let perMeter = 1 / 111_320.0

    /// An L: `north` metres north, then `east` metres east, a fix every 5 m, with the
    /// GPS `drift` metres west of the street the whole way.
    func corner(north: Double, east: Double, drift: Double = 0) -> [RouteHeatmap.Point] {
        let lonPerMeter = perMeter / cos(51.5 * .pi / 180)
        var points: [RouteHeatmap.Point] = []
        for d in stride(from: 0.0, through: north, by: 5) {
            points.append(.init(latitude: 51.5 + d * perMeter, longitude: -0.1 - drift * lonPerMeter))
        }
        for d in stride(from: 5.0, through: east, by: 5) {
            points.append(.init(latitude: 51.5 + north * perMeter, longitude: -0.1 + (d - drift) * lonPerMeter))
        }
        return points
    }

    @Test func aCornerGetsAPointOfItsOwn() {
        let points = corner(north: 300, east: 300)
        let kept = RouteSnapping.keyPoints(points)
        #expect(kept.first == 0)
        #expect(kept.last == points.count - 1)
        // The corner (index 60) is kept, give or take a fix.
        #expect(kept.contains { abs($0 - 60) <= 1 })
    }

    @Test func aLongStraightIsCutIntoShortPieces() {
        let points = corner(north: 2000, east: 0)
        let trace = RouteHeatmap.trace(points)
        let legs = RouteSnapping.legs(of: trace).joined()
        #expect(legs.count >= 4)
        #expect(legs.allSatisfy { $0.gpsMeters <= RouteSnapping.maxLegMeters + 30 })
    }

    @Test func aBelievableRouteReplacesTheGPS() {
        let gps = RouteHeatmap.trace(corner(north: 300, east: 300, drift: 25))
        let street = corner(north: 300, east: 300)
        let snapped = RouteSnapping.snapped(RouteSnapping.legs(of: gps)) { leg in
            // The router answers with the street's own line between the leg's ends.
            let from = street.min { RouteHeatmap.distance($0, leg.from) < RouteHeatmap.distance($1, leg.from) }!
            let to = street.min { RouteHeatmap.distance($0, leg.to) < RouteHeatmap.distance($1, leg.to) }!
            guard let a = street.firstIndex(of: from), let b = street.firstIndex(of: to), a <= b else { return nil }
            return Array(street[a...b])
        }
        let streetCells = Set(RouteHeatmap.trace(street).cells)
        let onStreet = snapped.cells.filter { streetCells.contains($0) }.count
        #expect(Double(onStreet) / Double(snapped.cells.count) > 0.8)
    }

    @Test func aDetourIsRefused() {
        let leg = RouteSnapping.Leg(
            from: .init(latitude: 51.5, longitude: -0.1),
            to: .init(latitude: 51.5 + 200 * perMeter, longitude: -0.1),
            gps: corner(north: 200, east: 0)
        )
        // Round three sides of a 300 m block instead.
        let detour = corner(north: 0, east: 300) + corner(north: 200, east: 0).map {
            .init(latitude: $0.latitude, longitude: $0.longitude + 300 * perMeter / cos(51.5 * .pi / 180))
        }
        #expect(!RouteSnapping.accepts(detour, for: leg))
        #expect(RouteSnapping.accepts(corner(north: 200, east: 0), for: leg))
    }

    @Test func noAnswerKeepsTheGPS() {
        let trace = RouteHeatmap.trace(corner(north: 300, east: 300))
        let snapped = RouteSnapping.snapped(RouteSnapping.legs(of: trace)) { _ in nil }
        #expect(Set(snapped.cells) == Set(trace.cells))
    }

    @Test func pausesStayApart() {
        let first = corner(north: 200, east: 0)
        let second = first.map { RouteHeatmap.Point(latitude: $0.latitude + 0.01, longitude: $0.longitude) }
        let trace = RouteHeatmap.trace(segments: [first, second])
        #expect(trace.segments.count == 2)
        #expect(Set(trace.cells).count == trace.cells.count)
    }

    @Test func theCacheDrawsTheSnappedRun() async throws {
        let cache = RouteHeatmapCache()
        let id = UUID(), date = Date(timeIntervalSince1970: 5)
        let key = RouteHeatmapCache.Key(id: id, date: date)
        let gps = corner(north: 300, east: 0, drift: 40)
        await cache.add([.init(id: id, date: date, route: try JSONEncoder().encode(gps))])
        let waiting = await cache.unsnapped([key])
        #expect(waiting.count == 1)
        let street = RouteHeatmap.trace(corner(north: 300, east: 0))
        await cache.setSnapped(street, for: key)
        #expect(await cache.unsnapped([key]).isEmpty)
        let map = await cache.heatmap(for: [key])
        #expect(map.cells.count == street.cells.count)
    }
}
