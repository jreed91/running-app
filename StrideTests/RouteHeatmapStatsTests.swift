import Foundation
import Testing
@testable import Stride

struct RouteHeatmapStatsTests {
    /// A straight run north from a point, `meters` long, one GPS fix every 5 m.
    func route(meters: Double, from latitude: Double = 51.5) -> [RouteHeatmap.Point] {
        let degreesPerMeter = 1 / 111_320.0
        return stride(from: 0.0, through: meters, by: 5).map {
            RouteHeatmap.Point(latitude: latitude + $0 * degreesPerMeter, longitude: -0.1)
        }
    }

    /// First half at 5:00/km, second half at 4:00/km, climbing 5% in the second half.
    func series(meters: Double) -> [SplitBucketing.DistancePoint] {
        var points: [SplitBucketing.DistancePoint] = []
        var time = 0.0
        for d in stride(from: 0.0, through: meters, by: 10) {
            let altitude = d <= meters / 2 ? 10 : 10 + (d - meters / 2) * 0.05
            points.append(.init(elapsedSeconds: time, cumulativeMeters: d, altitudeMeters: altitude))
            time += d < meters / 2 ? 3 : 2.4
        }
        return points
    }

    @Test func paceAndHillsLandWhereTheyHappened() {
        let stats = RouteHeatmap.stats(route: route(meters: 2000), series: series(meters: 2000), heartRate: [], durationSeconds: 0)
        #expect(!stats.isEmpty)
        let paces = stats.pace.filter { $0 >= 0 }
        let first = Double(stats.pace[2]), last = Double(stats.pace[stats.pace.count - 3])
        #expect(abs(first - 300) < 5)
        #expect(abs(last - 240) < 5)
        #expect(paces.count == stats.cells.count)
        #expect(Double(stats.grade[2]) < 0.5)
        #expect(abs(Double(stats.grade[stats.grade.count - 3]) - 5) < 0.5)
        #expect(stats.heartRate.allSatisfy { $0 < 0 })
    }

    @Test func heartRateWithoutSeriesSpreadsOverTheRun() {
        let hr = [Double](repeating: 120, count: 50) + [Double](repeating: 170, count: 50)
        let stats = RouteHeatmap.stats(route: route(meters: 2000), series: [], heartRate: hr, durationSeconds: 600)
        #expect(Double(stats.heartRate.first!) == 120)
        #expect(Double(stats.heartRate.last!) == 170)
        #expect(stats.pace.allSatisfy { $0 < 0 })
        #expect(stats.grade.allSatisfy { $0 < 0 })
    }

    @Test func implausibleHeartRateIsDropped() {
        let stats = RouteHeatmap.stats(route: route(meters: 200), series: [], heartRate: [0, 0, 0], durationSeconds: 60)
        #expect(stats.isEmpty)
    }

    @Test func gapsAreNotFilledIn() {
        let a = route(meters: 100)
        let b = route(meters: 100, from: 51.6)
        let spots = RouteHeatmap.walk(a + b)
        // Nothing between the two pieces, 11 km apart.
        let between = spots.filter { $0.point.latitude > 51.502 && $0.point.latitude < 51.599 }
        #expect(between.isEmpty)
    }

    @Test func statMapSpreadsLevelsAndAveragesRuns() {
        let slow = RouteHeatmap.stats(route: route(meters: 1000), series: series(meters: 1000), heartRate: [], durationSeconds: 0)
        let map = RouteHeatmap.statMap([slow, slow], stat: .pace)
        #expect(map.heatmap.runCount == 2)
        #expect(map.heatmap.maxRuns == 2)
        let levels = Set(map.heatmap.cells.map(\.level))
        #expect(levels.contains(1) && levels.contains(5))
        // Pace: faster is hotter, so the hottest cell is the fast half.
        #expect(map.low > map.high)
        let hottest = map.heatmap.cells.last!
        #expect(hottest.center.latitude > 51.5 + 500 / 111_320.0)
    }

    @Test func oneSlowSpotIsSmoothedIntoItsStreet() {
        // Steady 5:00/km with a single 20 m stretch at a standstill pace of 15:00/km.
        var points: [SplitBucketing.DistancePoint] = []
        var time = 0.0
        for d in stride(from: 0.0, through: 1000, by: 10) {
            points.append(.init(elapsedSeconds: time, cumulativeMeters: d))
            time += (500...510).contains(d) ? 9 : 3
        }
        let run = RouteHeatmap.stats(route: route(meters: 1000), series: points, heartRate: [], durationSeconds: 0)
        let raw = run.pace.filter { $0 >= 0 }.max() ?? 0
        let map = RouteHeatmap.statMap([run], stat: .pace)
        // The legend's slow end is pulled well under the raw spike.
        #expect(map.low < Double(raw))
    }

    @Test func theStatFollowsTheHeatmapsOwnLines() {
        let path = route(meters: 500)
        let stats = RouteHeatmap.stats(route: path, series: series(meters: 500), heartRate: [], durationSeconds: 0)
        let base = RouteHeatmap.build([RouteHeatmap.trace(path)])
        let coloured = RouteHeatmap.statMap([stats], stat: .pace).colouring(base)
        #expect(!coloured.cells.isEmpty)
        #expect(coloured.edges.count > 0)
        let baseCenters = Set(base.cells.map { "\($0.center.latitude),\($0.center.longitude)" })
        #expect(coloured.cells.allSatisfy { baseCenters.contains("\($0.center.latitude),\($0.center.longitude)") })
    }

    @Test func emptyRunsMakeAnEmptyMap() {
        #expect(RouteHeatmap.statMap([.empty], stat: .heartRate).isEmpty)
    }

    @Test func cacheRoundTripsThroughDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID()).plist")
        let routeData = try JSONEncoder().encode(route(meters: 500))
        let seriesData = try JSONEncoder().encode(series(meters: 500))
        let id = UUID(), date = Date(timeIntervalSince1970: 1_000)
        let cache = RouteStatsCache(storeURL: url)
        let key = RouteHeatmapCache.Key(id: id, date: date)
        #expect(await cache.missing([key]) == [id])
        await cache.add([.init(id: id, date: date, route: routeData, series: seriesData, heartRate: Data(), durationSeconds: 150)])
        await cache.keep(only: [id])
        let reloaded = RouteStatsCache(storeURL: url)
        #expect(await reloaded.missing([key]).isEmpty)
        #expect(await !reloaded.statMap(for: [key], stat: .pace).isEmpty)
        #expect(await reloaded.statMap(for: [key], stat: .heartRate).isEmpty)
    }
    /// The same series without altitudes, as a run imported from Health has.
    func flatSeries(meters: Double) -> [SplitBucketing.DistancePoint] {
        series(meters: meters).map { .init(elapsedSeconds: $0.elapsedSeconds, cumulativeMeters: $0.cumulativeMeters) }
    }

    /// Flat for the first half, climbing 5% in the second, one altitude per route point.
    func climb(_ route: [RouteHeatmap.Point], meters: Double) -> [Double?] {
        route.indices.map { i in
            let d = Double(i) * 5
            return d <= meters / 2 ? 10 : 10 + (d - meters / 2) * 0.05
        }
    }

    @Test func hillsComeFromTheRouteWhenTheSeriesHasNoAltitude() {
        let path = route(meters: 2000)
        let noAltitude = RouteHeatmap.stats(route: path, series: flatSeries(meters: 2000), heartRate: [], durationSeconds: 0)
        #expect(noAltitude.grade.allSatisfy { $0 < 0 })

        let stats = RouteHeatmap.stats(
            route: path, series: flatSeries(meters: 2000), heartRate: [], durationSeconds: 0,
            altitudes: climb(path, meters: 2000)
        )
        #expect(Double(stats.grade[2]) < 0.5)
        #expect(abs(Double(stats.grade[stats.grade.count - 3]) - 5) < 0.5)
        // Pace still comes from the series.
        #expect(abs(Double(stats.pace[2]) - 300) < 5)
    }

    @Test func hillsWorkWithNoSeriesAtAll() {
        let path = route(meters: 2000)
        let stats = RouteHeatmap.stats(route: path, series: [], heartRate: [], durationSeconds: 0, altitudes: climb(path, meters: 2000))
        #expect(!stats.isEmpty)
        #expect(abs(Double(stats.grade[stats.grade.count - 3]) - 5) < 0.5)
        #expect(stats.pace.allSatisfy { $0 < 0 })
    }

    @Test func theSeriesAltitudesWinOverTheRoutes() {
        let path = route(meters: 2000)
        let steep: [Double?] = path.indices.map { Double($0) * 5 * 0.2 }
        let stats = RouteHeatmap.stats(route: path, series: series(meters: 2000), heartRate: [], durationSeconds: 0, altitudes: steep)
        #expect(Double(stats.grade[2]) < 0.5)
    }

    @Test func fixesWithoutAltitudeAreSkipped() {
        let path = route(meters: 2000)
        var altitudes = climb(path, meters: 2000)
        for i in stride(from: 0, to: altitudes.count, by: 3) { altitudes[i] = nil }
        let stats = RouteHeatmap.stats(route: path, series: [], heartRate: [], durationSeconds: 0, altitudes: altitudes)
        #expect(abs(Double(stats.grade[stats.grade.count - 3]) - 5) < 0.5)
        // Fewer altitudes than fixes means they can't be matched up: no hills.
        let mismatched = RouteHeatmap.stats(route: path, series: [], heartRate: [], durationSeconds: 0, altitudes: [1, 2, 3])
        #expect(mismatched.isEmpty)
    }

    /// A route stored the way `Coordinate` stores it, with altitudes.
    struct StoredFix: Encodable {
        let latitude: Double
        let longitude: Double
        let altitude: Double?
    }

    @Test func theCacheReadsAltitudesFromAStoredRoute() throws {
        let path = route(meters: 2000)
        let fixes = zip(path, climb(path, meters: 2000)).map { StoredFix(latitude: $0.latitude, longitude: $0.longitude, altitude: $1) }
        let withAltitude = RouteStatsCache.Input(
            id: UUID(), date: Date(), route: try JSONEncoder().encode(fixes),
            series: try JSONEncoder().encode(flatSeries(meters: 2000)), heartRate: Data(), durationSeconds: 600
        )
        #expect(!withAltitude.lacksAltitude)
        let stats = try #require(RouteStatsCache.stats(of: withAltitude))
        #expect(abs(Double(stats.grade[stats.grade.count - 3]) - 5) < 0.5)

        let bare = RouteStatsCache.Input(
            id: UUID(), date: Date(), route: try JSONEncoder().encode(path),
            series: try JSONEncoder().encode(flatSeries(meters: 2000)), heartRate: Data(), durationSeconds: 600,
            healthKitID: "hk"
        )
        #expect(bare.lacksAltitude)
        let withSeriesAltitude = RouteStatsCache.Input(
            id: UUID(), date: Date(), route: try JSONEncoder().encode(path),
            series: try JSONEncoder().encode(series(meters: 2000)), heartRate: Data(), durationSeconds: 600
        )
        #expect(!withSeriesAltitude.lacksAltitude)
    }
}
