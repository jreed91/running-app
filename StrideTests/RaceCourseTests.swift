import Foundation
import Testing
@testable import Stride

/// Covers `RaceCourse` (reading a course GPX into an elevation profile) and `CoursePacing`
/// (turning a goal time into grade-adjusted splits over it).
///
/// Pinned on purpose: the Minetti et al. (2002) cost values, so the model cannot drift
/// into one of our own; that a flat course gives exactly the even-pace table; and that a
/// course's splits always add up to the goal time.
struct RaceCourseTests {

    // MARK: Fixtures

    /// Metres per degree of latitude on the sphere the course code uses.
    private static let metersPerDegree = RaceCourse.earthRadiusMeters * .pi / 180

    /// A straight course due north from the equator, one point every `spacing` metres,
    /// with heights from `elevation(distance)` (nil leaves `<ele>` out).
    private func points(
        lengthMeters: Double,
        spacing: Double = 10,
        elevation: (Double) -> Double?
    ) -> [(lat: Double, lon: Double, ele: Double?)] {
        let count = Int(lengthMeters / spacing)
        return (0...count).map { index in
            let distance = Double(index) * spacing
            return (lat: distance / Self.metersPerDegree, lon: 0, ele: elevation(distance))
        }
    }

    private func gpx(
        _ points: [(lat: Double, lon: Double, ele: Double?)],
        name: String? = "Test City Marathon",
        element: String = "trkpt",
        prefix: String = ""
    ) -> Data {
        let body = points.map { point -> String in
            let ele = point.ele.map { "<\(prefix)ele>\($0)</\(prefix)ele>" } ?? ""
            return "<\(prefix)\(element) lat=\"\(point.lat)\" lon=\"\(point.lon)\">\(ele)</\(prefix)\(element)>"
        }.joined(separator: "\n")
        let nameTag = name.map { "<\(prefix)metadata><\(prefix)name>\($0)</\(prefix)name></\(prefix)metadata>" } ?? ""
        let container = element == "trkpt"
            ? "<\(prefix)trk><\(prefix)trkseg>\(body)</\(prefix)trkseg></\(prefix)trk>"
            : "<\(prefix)rte>\(body)</\(prefix)rte>"
        let namespace = prefix.isEmpty
            ? "xmlns=\"http://www.topografix.com/GPX/1/1\""
            : "xmlns:\(prefix.dropLast())=\"http://www.topografix.com/GPX/1/1\""
        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <\(prefix)gpx version="1.1" creator="test" \(namespace)>\(nameTag)\(container)</\(prefix)gpx>
        """
        return Data(document.utf8)
    }

    private func course(
        lengthMeters: Double,
        elevation: @escaping (Double) -> Double
    ) throws -> RaceCourse {
        try RaceCourse.fromGPX(gpx(points(lengthMeters: lengthMeters, elevation: { elevation($0) })))
    }

    // MARK: Reading the file

    @Test func readsTrackPointsAndName() throws {
        let course = try course(lengthMeters: 10_000) { _ in 50 }
        #expect(course.name == "Test City Marathon")
        #expect(abs(course.lengthMeters - 10_000) < 1)
        #expect(course.samples.first?.distanceMeters == 0)
        #expect(course.samples.count == 201)
        #expect(course.climbMeters == 0)
        #expect(course.descentMeters == 0)
    }

    @Test func fallsBackToRoutePointsAndReadsPrefixedNamespaces() throws {
        let data = gpx(points(lengthMeters: 5_000, spacing: 250) { _ in 10 }, element: "rtept", prefix: "gpx:")
        let course = try RaceCourse.fromGPX(data)
        #expect(abs(course.lengthMeters - 5_000) < 1)
        #expect(course.name == "Test City Marathon")
    }

    @Test func rejectsFilesItCannotPace() {
        #expect(throws: RaceCourseImportError.unreadable) {
            try RaceCourse.fromGPX(Data("not xml <<".utf8))
        }
        #expect(throws: RaceCourseImportError.noPoints) {
            try RaceCourse.fromGPX(gpx([(lat: 0, lon: 0, ele: 1)]))
        }
        #expect(throws: RaceCourseImportError.noElevation) {
            try RaceCourse.fromGPX(gpx(points(lengthMeters: 5_000) { _ in nil }))
        }
        #expect(throws: RaceCourseImportError.tooShort) {
            try RaceCourse.fromGPX(gpx(points(lengthMeters: 500) { _ in 10 }))
        }
    }

    @Test func smoothsAwayASingleBadHeight() throws {
        // One point 20 m up on a flat road: a terrain model's bridge-in-the-river.
        let course = try course(lengthMeters: 5_000) { distance in
            abs(distance - 2_500) < 1 ? 30 : 10
        }
        #expect(course.climbMeters == 0)
        #expect(course.highestElevationMeters < 13)
    }

    @Test func countsARealClimb() throws {
        // 100 m of climb spread over 10 km.
        let course = try course(lengthMeters: 10_000) { $0 / 100 }
        #expect(course.climbMeters > 95)
        #expect(course.climbMeters <= 100)
        #expect(course.descentMeters == 0)
        #expect(abs(course.elevation(atMeters: 5_000) - 50) < 0.5)
    }

    // MARK: The model

    @Test func pinsMinettiCostOfRunning() {
        #expect(CoursePacing.costOfRunning(grade: 0) == 3.6)
        #expect(abs(CoursePacing.costOfRunning(grade: 0.10) - 5.968214) < 1e-9)
        #expect(abs(CoursePacing.costOfRunning(grade: -0.10) - 2.151706) < 1e-9)
        #expect(abs(CoursePacing.relativePace(grade: 0.02) - 1.11338) < 1e-5)
        #expect(abs(CoursePacing.relativePace(grade: -0.02) - 0.89691) < 1e-5)
        // A GPS spike is clamped, not believed.
        #expect(CoursePacing.costOfRunning(grade: 0.9) == CoursePacing.costOfRunning(grade: 0.30))
    }

    // MARK: Splits

    @Test func flatCourseGivesTheEvenPaceTable() throws {
        let course = try course(lengthMeters: 10_000) { _ in 20 }
        let even = RaceDayPlan.splits(distanceMeters: 10_000, paceSecondsPerKm: 300, unit: .metric)
        let paced = CoursePacing.splits(course: course, distanceMeters: 10_000, finishSeconds: 3_000, unit: .metric)

        #expect(paced.count == even.count)
        for (a, b) in zip(paced, even) {
            #expect(a.marker == b.marker)
            #expect(a.distanceMeters == b.distanceMeters)
            #expect(abs(a.elapsedSeconds - b.elapsedSeconds) < 0.01)
            #expect(abs(a.elevationChangeMeters ?? .nan) < 0.01)
        }
    }

    @Test func slowsOnTheClimbAndQuickensOnTheDescent() throws {
        // Up 60 m over the first 5 km, back down over the second.
        let course = try course(lengthMeters: 10_000) { distance in
            distance <= 5_000 ? distance * 0.012 : (10_000 - distance) * 0.012
        }
        let splits = CoursePacing.splits(course: course, distanceMeters: 10_000, finishSeconds: 3_000, unit: .metric)
        #expect(splits.count == 10)

        let segments = zip(splits, [0] + splits.dropLast().map(\.elapsedSeconds)).map { $0.elapsedSeconds - $1 }
        #expect(segments[1] > 300)   // km 2, climbing
        #expect(segments[8] < 300)   // km 9, descending
        #expect(segments[1] > segments[8])
        #expect(splits.last?.elapsedSeconds == 3_000)
        #expect((splits[1].elevationChangeMeters ?? 0) > 10)
        #expect((splits[8].elevationChangeMeters ?? 0) < -10)

        // Elevation changes add up to the course's start-to-finish change.
        let net = splits.compactMap(\.elevationChangeMeters).reduce(0, +)
        #expect(abs(net - (course.elevation(atMeters: 10_000) - course.elevation(atMeters: 0))) < 0.01)
    }

    @Test func stretchesACourseFileToTheRaceDistance() throws {
        // The file measures 10.3 km; the race is 10 km.
        let course = try course(lengthMeters: 10_300) { _ in 0 }
        let splits = CoursePacing.splits(course: course, distanceMeters: 10_000, finishSeconds: 3_000, unit: .metric)
        #expect(splits.count == 10)
        #expect(abs(splits[4].elapsedSeconds - 1_500) < 0.01)
        #expect(splits.last?.elapsedSeconds == 3_000)
    }

    @Test func keepsTheMarathonFinishRowInMiles() throws {
        let course = try course(lengthMeters: 42_195) { distance in 30 + 10 * sin(distance / 2_000) }
        let splits = CoursePacing.splits(course: course, distanceMeters: 42_195, finishSeconds: 12_600, unit: .imperial)
        #expect(splits.count == 27)
        #expect(splits.last?.isPartial == true)
        #expect(splits.last?.elapsedSeconds == 12_600)
        // Elapsed time only ever goes up.
        #expect(zip(splits, splits.dropFirst()).allSatisfy { $0.elapsedSeconds < $1.elapsedSeconds })
    }

    @Test func refusesACourseForAnotherDistance() throws {
        let half = try course(lengthMeters: 21_097) { _ in 0 }
        #expect(!CoursePacing.matches(half, distanceMeters: 42_195))
        #expect(CoursePacing.splits(course: half, distanceMeters: 42_195, finishSeconds: 12_600, unit: .metric).isEmpty)
        #expect(CoursePacing.matches(half, distanceMeters: 21_097.5))
    }

    @Test func roundTripsThroughCodable() throws {
        let course = try course(lengthMeters: 5_000) { $0 / 200 }
        let decoded = try JSONDecoder().decode(RaceCourse.self, from: JSONEncoder().encode(course))
        #expect(decoded == course)
    }
}
