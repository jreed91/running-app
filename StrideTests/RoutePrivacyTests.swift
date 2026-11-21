import Testing
import Foundation
import CoreLocation
@testable import Stride

// MARK: - RoutePrivacy tests
//
// What a shared run hides: the ends of every run and private places, and how the rest is
// split into pieces. Also the two places that use it: the share card and the GPX file.

struct RoutePrivacyTests {

    /// A straight run due north from (51.5, -0.1), one point every ~55.6 m.
    private func northRoute(points: Int) -> [Coordinate] {
        (0..<points).map { index in
            Coordinate(CLLocationCoordinate2D(latitude: 51.5 + Double(index) * 0.0005, longitude: -0.1))
        }
    }

    private func distanceAlong(_ route: [Coordinate], to index: Int) -> Double {
        guard index > 0 else { return 0 }
        return (1...index).reduce(0) { $0 + RoutePrivacy.distanceMeters(route[$1 - 1], route[$1]) }
    }

    // MARK: Distance

    @Test("Haversine distance matches a known span")
    func haversineDistance() {
        let a = Coordinate(CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1))
        let b = Coordinate(CLLocationCoordinate2D(latitude: 51.501, longitude: -0.1))
        // 0.001 degrees of latitude is about 111.2 m.
        #expect(abs(RoutePrivacy.distanceMeters(a, b) - 111.2) < 0.5)
        #expect(RoutePrivacy.distanceMeters(a, a) == 0)
    }

    // MARK: Off

    @Test("Off hides nothing: one piece, the whole route")
    func offHidesNothing() {
        let route = northRoute(points: 20)
        #expect(RoutePrivacy.off.visibleRanges(of: route) == [0..<20])
        #expect(!RoutePrivacy.off.hidesAnything)
    }

    @Test("Defaults hide 200 m at each end and no places")
    func defaults() {
        let privacy = RoutePrivacy()
        #expect(privacy.hideEndsMeters == 200)
        #expect(privacy.places.isEmpty)
        #expect(privacy.hidesAnything)
    }

    // MARK: Ends

    @Test("Hiding the ends drops every point closer than the distance to either end")
    func hidesEnds() throws {
        let route = northRoute(points: 40)   // ~2.17 km
        let privacy = RoutePrivacy(hideEndsMeters: 400, places: [])
        let ranges = privacy.visibleRanges(of: route)
        let range = try #require(ranges.first)
        #expect(ranges.count == 1)

        let total = distanceAlong(route, to: route.count - 1)
        for index in route.indices {
            let along = distanceAlong(route, to: index)
            let shouldShow = along >= 400 && total - along >= 400
            #expect(range.contains(index) == shouldShow, "point \(index) at \(along) m")
        }
    }

    @Test("A run too short to hide both ends shows nothing")
    func shortRunHidden() {
        let route = northRoute(points: 7)   // ~333 m
        #expect(RoutePrivacy(hideEndsMeters: 200, places: []).visibleRanges(of: route).isEmpty)
    }

    @Test("Fewer than two points shows nothing")
    func tooFewPoints() {
        #expect(RoutePrivacy.off.visibleRanges(of: []).isEmpty)
        #expect(RoutePrivacy.off.visibleRanges(of: northRoute(points: 1)).isEmpty)
    }

    // MARK: Places

    @Test("A place mid-route splits the route in two, with no point inside the circle")
    func placeSplitsRoute() {
        let route = northRoute(points: 40)
        let home = RoutePrivacy.Place(name: "Home", center: route[20], radiusMeters: 200)
        let privacy = RoutePrivacy(hideEndsMeters: 0, places: [home])
        let ranges = privacy.visibleRanges(of: route)

        #expect(ranges.count == 2)
        for range in ranges {
            for index in range {
                #expect(RoutePrivacy.distanceMeters(route[index], home.center) > 200)
            }
        }
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == 40)
    }

    @Test("A run that starts and ends at home loses both ends to the place")
    func homeLoop() {
        // Out 20 points and back the same way.
        let out = northRoute(points: 20)
        let route = out + out.reversed()
        let home = RoutePrivacy.Place(name: "Home", center: out[0], radiusMeters: 400)
        let ranges = RoutePrivacy(hideEndsMeters: 0, places: [home]).visibleRanges(of: route)

        #expect(!ranges.isEmpty)
        for range in ranges {
            #expect(range.lowerBound > 0)
            #expect(range.upperBound < route.count)
        }
    }

    @Test("Pieces of a single point are dropped")
    func singlePointPiecesDropped() {
        let route = northRoute(points: 5)
        // Hide points 1 and 3 only, leaving 0, 2 and 4 alone.
        let places = [1, 3].map {
            RoutePrivacy.Place(name: "p\($0)", center: route[$0], radiusMeters: 10)
        }
        #expect(RoutePrivacy(hideEndsMeters: 0, places: places).visibleRanges(of: route).isEmpty)
    }

    @Test("Segments are the coordinates of the visible ranges")
    func segmentsMatchRanges() {
        let route = northRoute(points: 40)
        let privacy = RoutePrivacy(hideEndsMeters: 300, places: [])
        let segments = privacy.visibleSegments(of: route)
        let ranges = privacy.visibleRanges(of: route)
        #expect(segments == ranges.map { Array(route[$0]) })
    }

    // MARK: Storage

    @Test("Settings round-trip through UserDefaults")
    func roundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "RoutePrivacyTests.\(UUID().uuidString)"))
        #expect(RoutePrivacy.load(from: defaults) == RoutePrivacy())

        let home = RoutePrivacy.Place(
            name: "Home",
            center: Coordinate(CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1)),
            radiusMeters: 800
        )
        let saved = RoutePrivacy(hideEndsMeters: 400, places: [home])
        saved.save(to: defaults)
        #expect(RoutePrivacy.load(from: defaults) == saved)
    }

    @Test("Stored settings missing a field still load, with the default for it")
    func decodesMissingFields() throws {
        let data = Data(#"{"places":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(RoutePrivacy.self, from: data)
        #expect(decoded.hideEndsMeters == RoutePrivacy.defaultHideEndsMeters)
    }

    // MARK: Share card

    private func run(route: [Coordinate]) -> RunWorkout {
        let workout = RunWorkout(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            distanceMeters: 2_000,
            durationSeconds: 600,
            workoutType: .easy
        )
        workout.routeCoordinates = route
        return workout
    }

    @Test("The share card draws one piece per visible segment")
    func shareCardSegments() {
        let route = northRoute(points: 40)
        let home = RoutePrivacy.Place(name: "Home", center: route[20], radiusMeters: 200)
        let model = ShareCardModel.make(
            from: run(route: route),
            unit: .metric,
            privacy: RoutePrivacy(hideEndsMeters: 0, places: [home])
        )
        #expect(model.routeSegments.count == 2)
        #expect(model.hasRoute)
        #expect(!model.isRouteHidden)
    }

    @Test("A fully hidden outdoor route is marked hidden, not treated as indoors")
    func shareCardHiddenRoute() {
        let model = ShareCardModel.make(
            from: run(route: northRoute(points: 7)),
            unit: .metric,
            privacy: RoutePrivacy(hideEndsMeters: 200, places: [])
        )
        #expect(!model.hasRoute)
        #expect(model.isRouteHidden)

        let indoor = ShareCardModel.make(from: run(route: []), unit: .metric, privacy: RoutePrivacy())
        #expect(!indoor.isRouteHidden)
    }

    // MARK: GPX

    @Test("A trimmed GPX has one track segment per visible piece and keeps true times")
    func gpxSegments() throws {
        let route = northRoute(points: 40)
        let home = RoutePrivacy.Place(name: "Home", center: route[20], radiusMeters: 200)
        let workout = run(route: route)
        let privacy = RoutePrivacy(hideEndsMeters: 300, places: [home])
        let gpx = try #require(GPXExport.document(for: workout, privacy: privacy))
        #expect(gpx.components(separatedBy: "<trkseg>").count - 1 == 2)
        #expect(!gpx.contains(String(format: "lat=\"%.6f\"", locale: Locale(identifier: "en_US_POSIX"), route[20].latitude)))

        // The first point shown keeps the time it was reached on the whole run, not the
        // run's start: times are laid over the full route before it is trimmed.
        let firstShown = try #require(privacy.visibleRanges(of: route).first?.lowerBound)
        let times = HealthKitRepository.sampleTimestamps(
            count: route.count,
            start: workout.date,
            end: workout.date.addingTimeInterval(workout.durationSeconds)
        )
        let firstPoint = try #require(gpx.range(of: "<trkpt "))
        let afterFirstPoint = gpx[firstPoint.upperBound...]
        #expect(afterFirstPoint.contains("<time>\(times[firstShown].formatted(.iso8601))</time>"))
        #expect(firstShown > 0)
    }

    @Test("A GPX with no privacy keeps every point in one segment")
    func gpxUntrimmed() throws {
        let gpx = try #require(GPXExport.document(for: run(route: northRoute(points: 10))))
        #expect(gpx.components(separatedBy: "<trkseg>").count - 1 == 1)
        #expect(gpx.components(separatedBy: "<trkpt ").count - 1 == 10)
    }

    @Test("A fully hidden route has no GPX")
    func gpxFullyHidden() {
        let gpx = GPXExport.document(
            for: run(route: northRoute(points: 7)),
            privacy: RoutePrivacy(hideEndsMeters: 200, places: [])
        )
        #expect(gpx == nil)
    }
}
