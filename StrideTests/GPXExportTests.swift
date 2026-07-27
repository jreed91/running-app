import Testing
import Foundation
import CoreLocation
@testable import Stride

// MARK: - GPXExport tests (B6 — route export)
//
// The document a run's route leaves the app as: whether one is produced at all, the track
// points and their timestamps, and the file name it lands under.

struct GPXExportTests {

    private func run(
        coordinates: [CLLocationCoordinate2D],
        date: Date = Date(timeIntervalSince1970: 1_800_000_000),
        durationSeconds: Double = 1_800,
        type: WorkoutType = .easy
    ) -> RunWorkout {
        let workout = RunWorkout(
            date: date,
            distanceMeters: 5_000,
            durationSeconds: durationSeconds,
            workoutType: type
        )
        workout.routeCoordinates = coordinates.map(Coordinate.init)
        return workout
    }

    // MARK: Nothing to export

    @Test("A run with no route produces no document")
    func routelessRunExportsNothing() {
        #expect(GPXExport.document(for: run(coordinates: [])) == nil)
    }

    // MARK: Document shape

    @Test("The document is a well-formed GPX 1.1 track")
    func documentIsGPX11() throws {
        let gpx = try #require(
            GPXExport.document(for: run(coordinates: [
                CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12),
                CLLocationCoordinate2D(latitude: 51.51, longitude: -0.13)
            ]))
        )
        #expect(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(gpx.contains("<gpx version=\"1.1\" creator=\"Stride\""))
        #expect(gpx.contains("http://www.topografix.com/GPX/1/1"))
        #expect(gpx.contains("<trkseg>"))
        #expect(gpx.hasSuffix("</gpx>"))
    }

    @Test("Every stored coordinate becomes one track point")
    func onePointPerCoordinate() throws {
        let coordinates = (0..<5).map {
            CLLocationCoordinate2D(latitude: 51.5 + Double($0) / 1_000, longitude: -0.12)
        }
        let gpx = try #require(GPXExport.document(for: run(coordinates: coordinates)))
        #expect(gpx.components(separatedBy: "<trkpt ").count - 1 == 5)
        #expect(gpx.components(separatedBy: "<time>").count - 1 == 6)  // 5 points + metadata
    }

    @Test("Coordinates are written with a dot decimal separator at six places")
    func coordinatesAreLocaleIndependent() throws {
        let gpx = try #require(
            GPXExport.document(for: run(coordinates: [
                CLLocationCoordinate2D(latitude: 51.500001, longitude: -0.125),
                CLLocationCoordinate2D(latitude: 51.6, longitude: -0.2)
            ]))
        )
        // A comma decimal separator here fails to parse in every GPX reader there is, so
        // the attributes are asserted exactly rather than merely for "contains a number".
        // (The metadata name carries a formatted date and legitimately has commas in it.)
        #expect(gpx.contains("lat=\"51.500001\""))
        #expect(gpx.contains("lon=\"-0.125000\""))
        #expect(gpx.contains("lat=\"51.600000\" lon=\"-0.200000\""))
    }

    // MARK: Timestamps

    @Test("Track-point times span the run and are written in UTC")
    func timestampsSpanTheRun() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let gpx = try #require(
            GPXExport.document(
                for: run(
                    coordinates: [
                        CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12),
                        CLLocationCoordinate2D(latitude: 51.6, longitude: -0.13)
                    ],
                    date: start,
                    durationSeconds: 600
                )
            )
        )
        let firstPoint = start.formatted(.iso8601)
        let lastPoint = start.addingTimeInterval(600).formatted(.iso8601)
        #expect(gpx.contains("<time>\(firstPoint)</time>"))
        #expect(gpx.contains("<time>\(lastPoint)</time>"))
        // `.iso8601`'s default zone is GMT, which is the only form the schema takes.
        #expect(firstPoint.hasSuffix("Z"))
    }

    // MARK: File and track names

    @Test("The file name carries the run's type and date, not its id")
    func fileNameIsHumanReadable() {
        let workout = run(coordinates: [], type: .longRun)
        let name = GPXExport.fileName(for: workout)
        #expect(name.hasPrefix("Stride-Long-Run-"))
        #expect(name.hasSuffix(".gpx"))
        #expect(!name.contains(workout.id.uuidString))
    }

    @Test("The track name is locale-stable, not formatted for the reader")
    func trackNameIsStable() throws {
        let gpx = try #require(
            GPXExport.document(
                for: run(
                    coordinates: [CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)],
                    type: .tempo
                )
            )
        )
        // `Tempo` is `displayName`, and the date is a fixed pattern — a file exported on a
        // French phone must name the same run the same way.
        #expect(gpx.contains("<name>Tempo run — "))
        #expect(gpx.contains("</name>"))
    }

    // MARK: The pure document builder

    @Test("A route and its timestamps must line up")
    func mismatchedTimestampsProduceNothing() {
        let point = Coordinate(CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12))
        #expect(
            GPXExport.document(
                coordinates: [point], timestamps: [], name: "x", startedAt: Date()
            ) == nil
        )
        #expect(
            GPXExport.document(
                coordinates: [], timestamps: [Date()], name: "x", startedAt: Date()
            ) == nil
        )
    }
}
