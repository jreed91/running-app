import Foundation
import Testing
@testable import Stride

/// Covers `RouteHeatmap` (routes on the grid, folded into heat cells) and
/// `RouteHeatmapCache` (each route traced once, deleted runs dropped).
struct RouteHeatmapTests {
    typealias Point = RouteHeatmap.Point

    /// A straight route north from `start`, a point every `step` metres.
    private func north(from start: Point, meters: Double, step: Double = 5) -> [Point] {
        stride(from: 0.0, through: meters, by: step).map {
            Point(latitude: start.latitude + $0 / 111_320, longitude: start.longitude)
        }
    }

    private let home = Point(latitude: 41.88, longitude: -87.63)

    // MARK: Grid

    @Test func nearbyPointsShareACell() {
        let a = RouteHeatmap.cell(of: home)
        let b = RouteHeatmap.cell(of: Point(latitude: home.latitude + 1 / 111_320, longitude: home.longitude))
        let far = RouteHeatmap.cell(of: Point(latitude: home.latitude + 100 / 111_320, longitude: home.longitude))
        #expect(a == b || abs(Int(a.y) - Int(b.y)) == 1)
        #expect(abs(Int(far.y) - Int(a.y)) == 5)
    }

    @Test func cellsStaySquareAwayFromTheEquator() {
        // 100 m east at 60°N is about five cells, not ten.
        let east = Point(latitude: 60, longitude: 10 + 100 / (111_320 * cos(60 * Double.pi / 180)))
        let a = RouteHeatmap.cell(of: Point(latitude: 60, longitude: 10))
        let b = RouteHeatmap.cell(of: east)
        #expect((4...6).contains(abs(Int(b.x) - Int(a.x))))
    }

    // MARK: Tracing

    @Test func aSparseRouteStillTouchesEveryCellAlongTheWay() {
        // Fixes 100 m apart: the trace fills in the cells between them.
        let trace = RouteHeatmap.trace(north(from: home, meters: 1_000, step: 100))
        #expect(trace.segments.count == 1)
        #expect((49...52).contains(trace.cells.count))
    }

    @Test func aGPSGapBreaksTheLine() {
        let first = north(from: home, meters: 200)
        let jump = Point(latitude: home.latitude + 2_000 / 111_320, longitude: home.longitude)
        let second = north(from: jump, meters: 200)
        let trace = RouteHeatmap.trace(first + second)
        #expect(trace.segments.count == 2)
        // Nothing drawn across the 1.8 km between them.
        #expect(trace.cells.count < 30)
    }

    @Test func lostFixesAreIgnored() {
        let route = north(from: home, meters: 200) + [Point(latitude: 0, longitude: 0)] + north(from: home, meters: 200)
        let trace = RouteHeatmap.trace(route)
        #expect(trace.cells.allSatisfy { abs(Int($0.y) - Int(RouteHeatmap.cell(of: home).y)) < 20 })
    }

    @Test func decodesTheStoredRouteBlob() throws {
        let blob = Data(#"[{"latitude":41.88,"longitude":-87.63},{"latitude":41.881,"longitude":-87.63}]"#.utf8)
        let trace = try #require(RouteHeatmap.trace(routeData: blob))
        #expect(!trace.isEmpty)
        #expect(RouteHeatmap.trace(routeData: Data()) == nil)
        #expect(RouteHeatmap.trace(routeData: Data("nope".utf8)) == nil)
    }

    @Test func aTraceSurvivesPackingToWithinAFewMillimetres() throws {
        let trace = RouteHeatmap.trace(north(from: home, meters: 800, step: 7))
        let unpacked = try #require(RouteHeatmap.Trace(packed: trace.packed()))
        #expect(unpacked.cells == trace.cells)
        #expect(unpacked.segments == trace.segments)
        for (a, b) in zip(unpacked.centers, trace.centers) {
            #expect(RouteHeatmap.distance(a, b) < 0.01)
        }
        // About 12 bytes a cell, a fraction of the JSON.
        #expect(trace.packed().count < trace.cells.count * 12 + trace.segments.joined().count * 4 + 64)
    }

    @Test func aDamagedPackIsRejected() {
        let packed = RouteHeatmap.trace(north(from: home, meters: 300)).packed()
        #expect(RouteHeatmap.Trace(packed: packed.prefix(packed.count - 3)) == nil)
        #expect(RouteHeatmap.Trace(packed: Data([1, 2])) == nil)
    }

    // MARK: Building

    @Test func theStreetRunMostIsTheHottest() {
        let street = north(from: home, meters: 500)
        let otherStreet = north(from: Point(latitude: home.latitude, longitude: home.longitude + 0.01), meters: 500)
        let traces = (0..<10).map { _ in RouteHeatmap.trace(street) } + [RouteHeatmap.trace(otherStreet)]
        let heatmap = RouteHeatmap.build(traces)
        #expect(heatmap.runCount == 11)
        #expect(heatmap.maxRuns == 10)
        #expect(heatmap.cells.filter { $0.level == RouteHeatmap.levels }.count == heatmap.cells.filter { $0.runs == 10 }.count)
        #expect(heatmap.cells.filter { $0.level == 1 }.allSatisfy { $0.runs == 1 })
        // Hottest drawn last, on top.
        #expect(heatmap.cells.last?.level == RouteHeatmap.levels)
        #expect(heatmap.cells.map(\.runs) == heatmap.cells.map(\.runs).sorted())
        // Each street counted once: about a kilometre of ground, not 5.5.
        #expect((900...1_100).contains(heatmap.uniqueMeters))
    }

    @Test func anOutAndBackCountsOnce() {
        let out = north(from: home, meters: 500)
        let heatmap = RouteHeatmap.build([RouteHeatmap.trace(out + out.reversed())])
        #expect(heatmap.maxRuns == 1)
        #expect((450...550).contains(heatmap.uniqueMeters))
    }

    @Test func oneCellPerSquareHoweverManyRuns() {
        let street = RouteHeatmap.trace(north(from: home, meters: 2_000))
        let once = RouteHeatmap.build([street])
        let often = RouteHeatmap.build(Array(repeating: street, count: 300))
        #expect(often.cells.count == once.cells.count)
        #expect(often.runCount == 300)
        #expect(often.maxRuns == 300)
    }

    /// A street run many times with GPS wandering a few metres either side: a band of
    /// cells, but still one street's worth of ground.
    @Test func gpsWanderDoesNotMultiplyTheGround() {
        var generator = SeededGenerator(seed: 7)
        let traces = (0..<60).map { _ in
            RouteHeatmap.trace(north(from: home, meters: 2_000).map {
                Point(
                    latitude: $0.latitude + Double.random(in: -4...4, using: &generator) / 111_320,
                    longitude: $0.longitude + Double.random(in: -4...4, using: &generator) / 82_900
                )
            })
        }
        let heatmap = RouteHeatmap.build(traces)
        #expect((1_800...2_600).contains(heatmap.uniqueMeters))
    }

    @Test func aDiagonalStreetIsMeasuredAlongItsLength() {
        // 1 km north-east.
        let route = stride(from: 0.0, through: 1_000, by: 5).map {
            Point(
                latitude: home.latitude + $0 * 0.7071 / 111_320,
                longitude: home.longitude + $0 * 0.7071 / (111_320 * cos(41.88 * Double.pi / 180))
            )
        }
        let heatmap = RouteHeatmap.build([RouteHeatmap.trace(route)])
        #expect((900...1_250).contains(heatmap.uniqueMeters))
    }

    @Test func aJunctionCountsBothStreets() {
        let stem = north(from: home, meters: 400)
        let middle = Point(latitude: home.latitude + 200 / 111_320, longitude: home.longitude)
        let branch = stride(from: 0.0, through: 300, by: 5).map {
            Point(latitude: middle.latitude, longitude: middle.longitude + $0 / (111_320 * cos(41.88 * Double.pi / 180)))
        }
        let heatmap = RouteHeatmap.build([RouteHeatmap.trace(stem), RouteHeatmap.trace(branch)])
        #expect((600...800).contains(heatmap.uniqueMeters))
    }

    @Test func eachBuildIsItsOwnMap() {
        let traces = [RouteHeatmap.trace(north(from: home, meters: 800))]
        let first = RouteHeatmap.build(traces)
        let second = RouteHeatmap.build(traces)
        // Equal only to itself, so views redraw for a new build without comparing cells.
        #expect(first != second)
        #expect(first == first)
        #expect(first.cells == second.cells)
    }

    @Test func noRoutesIsAnEmptyMap() {
        #expect(RouteHeatmap.build([]) == .empty)
        #expect(RouteHeatmap.build([RouteHeatmap.trace([home])]) == .empty)
    }

    @Test func levelsRiseWithRuns() {
        #expect(RouteHeatmap.level(runs: 0, maxRuns: 10) == 0)
        #expect(RouteHeatmap.level(runs: 1, maxRuns: 1) == 1)
        #expect(RouteHeatmap.level(runs: 1, maxRuns: 400) == 1)
        #expect(RouteHeatmap.level(runs: 400, maxRuns: 400) == RouteHeatmap.levels)
        let levels = (1...400).map { RouteHeatmap.level(runs: $0, maxRuns: 400) }
        #expect(levels == levels.sorted())
        // Logarithmic: a street run 20 times out of 400 is well above the coolest colour.
        #expect(RouteHeatmap.level(runs: 20, maxRuns: 400) >= 3)
    }

    // MARK: Cache

    private func blob(_ points: [Point]) -> Data {
        try! JSONEncoder().encode(points)
    }

    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func tracesEachRouteOnce() async {
        let cache = RouteHeatmapCache()
        let input = RouteHeatmapCache.Input(id: UUID(), date: day, route: blob(north(from: home, meters: 500)))
        #expect(await cache.missing([input.key]) == [input.id])
        await cache.add([input])
        #expect(await cache.missing([input.key]).isEmpty)
        let map = await cache.heatmap(for: [input.key])
        #expect(map.runCount == 1)
        #expect(await cache.traced == 1)
    }

    @Test func aRunWithNoRouteIsNotAskedForAgain() async {
        let cache = RouteHeatmapCache()
        let indoor = RouteHeatmapCache.Input(id: UUID(), date: day, route: Data())
        await cache.add([indoor])
        #expect(await cache.missing([indoor.key]).isEmpty)
        #expect(await cache.heatmap(for: [indoor.key]) == .empty)
    }

    @Test func aChangedDateIsTracedAgain() async {
        let cache = RouteHeatmapCache()
        let id = UUID()
        await cache.add([.init(id: id, date: day, route: blob(north(from: home, meters: 500)))])
        let moved = RouteHeatmapCache.Key(id: id, date: day.addingTimeInterval(60))
        #expect(await cache.missing([moved]) == [id])
        #expect(await cache.heatmap(for: [moved]) == .empty)
    }

    @Test func theMapShowsOnlyTheRunsAskedFor() async {
        let cache = RouteHeatmapCache()
        let a = RouteHeatmapCache.Input(id: UUID(), date: day, route: blob(north(from: home, meters: 500)))
        let b = RouteHeatmapCache.Input(id: UUID(), date: day, route: blob(north(from: home, meters: 500)))
        await cache.add([a, b])
        #expect(await cache.heatmap(for: [a.key, b.key]).maxRuns == 2)
        #expect(await cache.heatmap(for: [a.key]).maxRuns == 1)
    }

    @Test func deletedRunsDropOutAndTheCacheSurvivesARelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heatmap-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let kept = RouteHeatmapCache.Input(id: UUID(), date: day, route: blob(north(from: home, meters: 500)))
        let deleted = RouteHeatmapCache.Input(id: UUID(), date: day, route: blob(north(from: home, meters: 500)))

        let first = RouteHeatmapCache(storeURL: url)
        await first.add([kept, deleted])
        await first.keep(only: [kept.id])

        let relaunched = RouteHeatmapCache(storeURL: url)
        #expect(await relaunched.missing([kept.key]).isEmpty)
        #expect(await relaunched.missing([deleted.key]) == [deleted.id])
        #expect(await relaunched.heatmap(for: [kept.key]).runCount == 1)
        #expect(await relaunched.traced == 0)
    }
}

/// Covers "which runs went here?": `RouteHeatmap.cells(around:)` and
/// `RouteHeatmapCache.runs(near:)`.
struct RouteHeatmapSpotTests {
    typealias Point = RouteHeatmap.Point

    private let home = Point(latitude: 41.88, longitude: -87.63)
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func north(from start: Point, meters: Double) -> [Point] {
        stride(from: 0.0, through: meters, by: 5).map {
            Point(latitude: start.latitude + $0 / 111_320, longitude: start.longitude)
        }
    }

    private func east(of point: Point, meters: Double) -> Point {
        Point(latitude: point.latitude, longitude: point.longitude + meters / (111_320 * cos(point.latitude * .pi / 180)))
    }

    @Test func theAreaGrowsWithTheRadius() {
        #expect(RouteHeatmap.cells(around: home, radiusMeters: 0).count == 1)
        #expect(RouteHeatmap.cells(around: home, radiusMeters: 20).count == 9)
        #expect(RouteHeatmap.cells(around: home, radiusMeters: 40).count == 25)
        #expect(RouteHeatmap.cells(around: home, radiusMeters: 20).contains(RouteHeatmap.cell(of: home)))
    }

    @Test func findsTheRunsThatWentThroughATap() async {
        let cache = RouteHeatmapCache()
        let onStreet = RouteHeatmapCache.Input(id: UUID(), date: day, route: try! JSONEncoder().encode(north(from: home, meters: 500)))
        let blockOver = RouteHeatmapCache.Input(
            id: UUID(), date: day, route: try! JSONEncoder().encode(north(from: east(of: home, meters: 200), meters: 500))
        )
        await cache.add([onStreet, blockOver])
        let keys = [onStreet.key, blockOver.key]
        let tap = east(of: Point(latitude: home.latitude + 250 / 111_320, longitude: home.longitude), meters: 15)
        #expect(await cache.runs(near: tap, radiusMeters: 30, among: keys) == [onStreet.id])
        // A run not on the map isn't listed even if it went there.
        #expect(await cache.runs(near: tap, radiusMeters: 30, among: [blockOver.key]).isEmpty)
        // A wide tap takes in both streets.
        #expect(await cache.runs(near: east(of: tap, meters: 85), radiusMeters: 120, among: keys).count == 2)
    }
}

/// A small repeatable random source, so the GPS-wander test draws the same wander each run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Covers `RouteHeatmap.newGround(in:before:)`: streets first run in a period.
struct RouteHeatmapNewGroundTests {
    typealias Point = RouteHeatmap.Point

    private let home = Point(latitude: 41.88, longitude: -87.63)

    private func north(from start: Point, meters: Double) -> [Point] {
        stride(from: 0.0, through: meters, by: 5).map {
            Point(latitude: start.latitude + $0 / 111_320, longitude: start.longitude)
        }
    }

    @Test func aStreetRunBeforeIsNotNew() {
        let street = RouteHeatmap.trace(north(from: home, meters: 500))
        #expect(RouteHeatmap.newGround(in: [street], before: [street]) == .none)
    }

    @Test func gpsWanderOnAKnownStreetIsNotNew() {
        let street = RouteHeatmap.trace(north(from: home, meters: 500))
        // The same street, 12 m to the east.
        let wandered = RouteHeatmap.trace(north(
            from: Point(latitude: home.latitude, longitude: home.longitude + 12 / 82_900),
            meters: 500
        ))
        #expect(RouteHeatmap.newGround(in: [wandered], before: [street]).cells.isEmpty)
    }

    @Test func everythingIsNewWithNothingBefore() {
        let street = RouteHeatmap.trace(north(from: home, meters: 500))
        let ground = RouteHeatmap.newGround(in: [street], before: [])
        #expect(ground.cells.count == street.cells.count)
        #expect((450...550).contains(ground.meters))
    }

    @Test func onlyTheExtensionIsNew() {
        let usual = RouteHeatmap.trace(north(from: home, meters: 500))
        let longer = RouteHeatmap.trace(north(from: home, meters: 1_000))
        let ground = RouteHeatmap.newGround(in: [longer], before: [usual])
        #expect((440...540).contains(ground.meters))
        // Every new cell is past where the usual street ends.
        #expect(ground.cells.allSatisfy { $0.latitude > home.latitude + 500 / 111_320 })
    }

    @Test func aNewStreetRunTwiceInThePeriodCountsOnce() {
        let fresh = RouteHeatmap.trace(north(from: home, meters: 500))
        let ground = RouteHeatmap.newGround(in: [fresh, fresh], before: [])
        #expect((450...550).contains(ground.meters))
    }
}
