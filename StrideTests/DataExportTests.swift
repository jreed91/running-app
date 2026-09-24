import Testing
import Foundation
import CoreLocation
@testable import Stride

// MARK: - DataExport tests (B6 — full-data export)
//
// The archive a runner's whole history leaves the app as: which files it holds, what each
// CSV row says, how free text is escaped, and that routes never overwrite each other.

struct DataExportTests {

    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(
        minutesAfterReference: Double = 0,
        distanceMeters: Double = 5_000,
        durationSeconds: Double = 1_500,
        type: WorkoutType = .easy,
        route: [CLLocationCoordinate2D] = []
    ) -> RunWorkout {
        let workout = RunWorkout(
            date: referenceDate.addingTimeInterval(minutesAfterReference * 60),
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            workoutType: type
        )
        workout.routeCoordinates = route.map(Coordinate.init)
        return workout
    }

    private let sampleRoute = [
        CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12),
        CLLocationCoordinate2D(latitude: 51.501, longitude: -0.121),
    ]

    /// Rows of a CSV as split fields. Only good for fields with no quoted commas, which is
    /// every row these tests read this way.
    private func rows(_ csv: String) -> [[String]] {
        csv.components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: ",") }
    }

    private func column(_ name: String) throws -> Int {
        try #require(DataExport.runsHeader.firstIndex(of: name))
    }

    // MARK: Archive layout

    @Test("The archive holds a README, three CSVs and one GPX per routed workout")
    func archiveLayout() {
        let entries = DataExport.entries(
            runs: [
                run(route: sampleRoute),
                run(minutesAfterReference: 60 * 24, type: .tempo),  // indoor-like: no route
            ],
            strengthSessions: [StrengthWorkout(date: referenceDate, durationSeconds: 1_800)],
            shoes: [],
            exportedAt: referenceDate
        )
        let paths = entries.map(\.path)
        #expect(Array(paths.prefix(4)) == ["README.txt", "runs.csv", "strength.csv", "shoes.csv"])
        #expect(paths.filter { $0.hasPrefix("routes/") }.count == 1)
        #expect(paths.last?.hasSuffix(".gpx") == true)
    }

    @Test("An empty history still exports headers, not nothing")
    func emptyHistory() throws {
        let entries = DataExport.entries(runs: [], strengthSessions: [], shoes: [], exportedAt: referenceDate)
        let runsCSV = try #require(entries.first { $0.path == "runs.csv" })
        #expect(runsCSV.contents == DataExport.runsHeader.joined(separator: ",") + "\r\n")
        #expect(entries.count == 4)
    }

    @Test("Walks and cross-training are exported alongside runs")
    func everythingRecordedIsExported() {
        let csv = DataExport.runsCSV(
            [run(), run(type: .walk), run(type: .crossTraining)],
            shoes: [],
            routeFiles: [:]
        )
        let types = rows(csv).dropFirst().map { $0[2] }
        #expect(types == ["Easy", "Walk", "Cross Training"])
    }

    // MARK: Run rows

    @Test("A run row carries its numbers in fixed, locale-free form")
    func runRowNumbers() throws {
        let workout = run(distanceMeters: 10_000, durationSeconds: 3_000)
        workout.averageHeartRate = 151.4
        workout.elevationGainMeters = 42.3
        workout.feel = .hard

        let fields = try #require(rows(DataExport.runsCSV([workout], shoes: [], routeFiles: [:])).last)
        func field(_ name: String) throws -> String { try fields[column(name)] }

        #expect(try field("distance_m") == "10000.0")
        #expect(try field("duration_s") == "3000")
        #expect(try field("avg_pace_s_per_km") == "300.0")
        #expect(try field("avg_heart_rate_bpm") == "151")
        #expect(try field("elevation_gain_m") == "42.3")
        #expect(try field("feel") == "4")
        #expect(try field("max_heart_rate_bpm") == "")
        #expect(try field("start_time_utc") == referenceDate.formatted(.iso8601))
    }

    @Test("A session with no distance exports an empty pace, not zero")
    func noPaceIsEmpty() throws {
        let session = run(distanceMeters: 0, durationSeconds: 2_400, type: .crossTraining)
        let fields = try #require(rows(DataExport.runsCSV([session], shoes: [], routeFiles: [:])).last)
        #expect(try fields[column("avg_pace_s_per_km")] == "")
    }

    @Test("A run names its shoe, and a deleted shoe leaves the cell empty")
    func shoeNames() throws {
        let shoe = Shoe(name: "Pegasus 41", replacementDistanceMeters: 800_000)
        let withShoe = run()
        withShoe.shoeID = shoe.id
        let withDeletedShoe = run(minutesAfterReference: 60)
        withDeletedShoe.shoeID = UUID()

        let shoeColumn = try column("shoe")
        let values = rows(DataExport.runsCSV([withShoe, withDeletedShoe], shoes: [shoe], routeFiles: [:]))
            .dropFirst()
            .map { $0[shoeColumn] }
        #expect(values == ["Pegasus 41", ""])
    }

    // MARK: CSV escaping

    @Test("Fields with commas, quotes or line breaks are quoted per RFC 4180")
    func escaping() {
        #expect(DataExport.escapedField("plain") == "plain")
        #expect(DataExport.escapedField("hills, then flat") == "\"hills, then flat\"")
        #expect(DataExport.escapedField("felt \"great\"") == "\"felt \"\"great\"\"\"")
        #expect(DataExport.escapedField("line one\nline two") == "\"line one\nline two\"")
    }

    @Test("A note with a comma stays in one field")
    func notesAreEscapedInRows() {
        let workout = run()
        workout.notes = "windy, cold"
        let csv = DataExport.runsCSV([workout], shoes: [], routeFiles: [:])
        #expect(csv.contains(",\"windy, cold\","))
    }

    // MARK: Routes

    @Test("Two routed workouts in the same minute get distinct file names")
    func routeNamesDoNotCollide() {
        let first = run(route: sampleRoute)
        let second = run(route: sampleRoute)
        let names = DataExport.routeFileNames(for: [first, second])
        #expect(Set(names.values).count == 2)
        #expect(names.values.contains { $0.hasSuffix("-2.gpx") })
    }

    @Test("Workouts without a route get no file name")
    func routelessRunHasNoRouteFile() {
        let names = DataExport.routeFileNames(for: [run()])
        #expect(names.isEmpty)
    }

    @Test("The run row points at its route file")
    func runRowNamesRouteFile() throws {
        let routed = run(route: sampleRoute)
        let entries = DataExport.entries(runs: [routed], strengthSessions: [], shoes: [], exportedAt: referenceDate)
        let gpxPath = try #require(entries.last?.path)
        let runsCSV = try #require(entries.first { $0.path == "runs.csv" }?.contents)
        #expect(runsCSV.contains(gpxPath))
    }

    // MARK: Strength

    @Test("A strength row totals completed sets and reps and counts skipped sets")
    func strengthTotals() throws {
        let session = StrengthWorkout(date: referenceDate, durationSeconds: 1_800, notes: "gym")
        session.completedSets = [
            CompletedStrengthSet(exerciseIndex: 0, setIndex: 0, completedReps: 10, actualWeight: nil, skipped: false),
            CompletedStrengthSet(exerciseIndex: 0, setIndex: 1, completedReps: 8, actualWeight: nil, skipped: false),
            CompletedStrengthSet(exerciseIndex: 1, setIndex: 0, completedReps: 0, actualWeight: nil, skipped: true),
        ]
        let fields = try #require(rows(DataExport.strengthCSV([session])).last)
        #expect(Array(fields[2...]) == ["1800", "2", "1", "18", "gym"])
    }

    // MARK: Writing

    @Test("The writer produces a zip archive")
    func writerProducesZip() throws {
        let entries = DataExport.entries(
            runs: [run(route: sampleRoute)],
            strengthSessions: [],
            shoes: [],
            exportedAt: referenceDate
        )
        let url = try DataExportWriter.writeArchive(entries: entries, name: "DataExportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.pathExtension == "zip")
        let data = try Data(contentsOf: url)
        // Every zip starts with the local-file-header signature "PK\u{03}\u{04}".
        #expect(Array(data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
    }
}
