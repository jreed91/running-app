import Foundation

/// Everything the runner has recorded, laid out as files another tool can read (B6).
///
/// The route half of B6 got a single run's trace out as GPX. This is the other half: the
/// counterpart to "Reset all data", so a runner leaving Stride — or just keeping their own
/// copy — takes their whole history with them rather than one route at a time.
///
/// The archive is:
///
/// ```text
/// Stride-Export-2026-09-24/
///   README.txt      what each file is and which units it uses
///   runs.csv        one row per recorded workout: runs, walks and cross-training
///   strength.csv    one row per strength session
///   shoes.csv       one row per pair
///   routes/*.gpx    one GPX per outdoor workout that has a route
/// ```
///
/// Everything *recorded* goes in, walks and cross-training included — the AGENTS.md split
/// between "what the runner recorded" (take everything) and "what counts as running"
/// (`runsOnly`). An export is the first kind of question, and the `type` column lets the
/// reader filter.
///
/// Pure string building, like `GPXExport`: `entries` is what the tests assert on, and
/// `DataExportWriter` is the only part that touches the file system.
enum DataExport {

    /// One file in the archive: its path relative to the archive's root, and its text.
    struct Entry: Equatable, Sendable {
        let path: String
        let contents: String
    }

    /// Every file in the archive, README first.
    ///
    /// `shoes` are passed in so a run's `shoe` column can name the pair rather than print
    /// a UUID nobody can read; a run pointing at a pair that has since been deleted gets an
    /// empty cell rather than a dangling ID.
    static func entries(
        runs: [RunWorkout],
        strengthSessions: [StrengthWorkout],
        shoes: [Shoe],
        exportedAt: Date
    ) -> [Entry] {
        let sortedRuns = runs.sorted { $0.date < $1.date }
        let routeFiles = routeFileNames(for: sortedRuns)

        var entries = [
            Entry(path: "README.txt", contents: readme(exportedAt: exportedAt)),
            Entry(
                path: "runs.csv",
                contents: runsCSV(sortedRuns, shoes: shoes, routeFiles: routeFiles)
            ),
            Entry(
                path: "strength.csv",
                contents: strengthCSV(strengthSessions.sorted { $0.date < $1.date })
            ),
            Entry(path: "shoes.csv", contents: shoesCSV(shoes.sorted { $0.startDate < $1.startDate })),
        ]
        for run in sortedRuns {
            guard let fileName = routeFiles[run.id],
                  let document = GPXExport.document(for: run) else { continue }
            entries.append(Entry(path: "routes/\(fileName)", contents: document))
        }
        return entries
    }

    /// The archive's name without an extension, e.g. `Stride-Export-2026-09-24`. Also the
    /// name of the folder the archive unpacks to.
    static func archiveName(exportedAt: Date) -> String {
        "Stride-Export-\(localDateString(exportedAt, format: "yyyy-MM-dd"))"
    }

    // MARK: - CSV

    static let runsHeader = [
        "id", "start_time_utc", "type", "location",
        "distance_m", "duration_s", "avg_pace_s_per_km",
        "avg_heart_rate_bpm", "max_heart_rate_bpm", "elevation_gain_m", "avg_cadence_spm",
        "feel", "shoe", "temperature_c", "notes", "route_file",
    ]

    static func runsCSV(
        _ runs: [RunWorkout],
        shoes: [Shoe],
        routeFiles: [UUID: String]
    ) -> String {
        let shoeNames = Dictionary(shoes.map { ($0.id, $0.name) }) { first, _ in first }
        let rows = runs.map { run -> [String] in
            [
                run.id.uuidString,
                timestampString(run.date),
                // `rawValue`s, not localized names: the file is read by a spreadsheet or a
                // script, and two exports of the same history should not differ because
                // the phone's language changed in between (the GPXExport rule).
                run.workoutType.rawValue,
                run.workoutLocation.rawValue,
                number(run.distanceMeters, decimals: 1),
                number(run.durationSeconds, decimals: 0),
                // Zero pace is how a distance-less session stores "no pace"; an empty cell
                // says that honestly where `0` would read as infinitely fast.
                run.averagePaceSecondsPerKm > 0 ? number(run.averagePaceSecondsPerKm, decimals: 1) : "",
                optionalNumber(run.averageHeartRate, decimals: 0),
                optionalNumber(run.maxHeartRate, decimals: 0),
                optionalNumber(run.elevationGainMeters, decimals: 1),
                optionalNumber(run.averageCadenceStepsPerMinute, decimals: 0),
                run.feelRaw.map(String.init) ?? "",
                run.shoeID.flatMap { shoeNames[$0] } ?? "",
                optionalNumber(run.weather?.temperatureCelsius, decimals: 1),
                run.notes ?? "",
                routeFiles[run.id].map { "routes/\($0)" } ?? "",
            ]
        }
        return csv(header: runsHeader, rows: rows)
    }

    static let strengthHeader = [
        "id", "start_time_utc", "duration_s", "sets_completed", "sets_skipped", "total_reps", "notes",
    ]

    /// One row per session. The logged sets name their exercise by its index into the
    /// scheduled session's plan, not by name, so a per-set file would be a column of
    /// numbers that mean nothing outside the app — the session totals are what survive
    /// the trip.
    static func strengthCSV(_ sessions: [StrengthWorkout]) -> String {
        let rows = sessions.map { session -> [String] in
            let sets = session.completedSets
            let completed = sets.filter { !$0.skipped }
            return [
                session.id.uuidString,
                timestampString(session.date),
                number(session.durationSeconds, decimals: 0),
                String(completed.count),
                String(sets.count - completed.count),
                String(completed.reduce(0) { $0 + $1.completedReps }),
                session.notes ?? "",
            ]
        }
        return csv(header: strengthHeader, rows: rows)
    }

    static let shoesHeader = [
        "id", "name", "in_use_from", "starting_distance_m", "replace_at_m", "retired_on",
    ]

    static func shoesCSV(_ shoes: [Shoe]) -> String {
        let rows = shoes.map { shoe -> [String] in
            [
                shoe.id.uuidString,
                shoe.name,
                localDateString(shoe.startDate, format: "yyyy-MM-dd"),
                number(shoe.startingDistanceMeters, decimals: 0),
                number(shoe.replacementDistanceMeters, decimals: 0),
                shoe.retiredAt.map { localDateString($0, format: "yyyy-MM-dd") } ?? "",
            ]
        }
        return csv(header: shoesHeader, rows: rows)
    }

    /// RFC 4180: comma-separated, CRLF line endings, and any field holding a comma, a
    /// quote or a line break wrapped in quotes with its quotes doubled. Notes are free
    /// text and are the field this exists for.
    static func csv(header: [String], rows: [[String]]) -> String {
        ([header] + rows)
            .map { $0.map(escapedField).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
    }

    static func escapedField(_ field: String) -> String {
        let needsQuoting = field.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Routes

    /// The GPX file name for each run that has a route, keyed by run ID.
    ///
    /// `GPXExport.fileName` is dated to the minute, which is unique for one run shared at a
    /// time but not across a whole history — a run and a walk imported for the same minute,
    /// or a double-recorded session, would overwrite each other in the archive. The second
    /// and later holders of a name get `-2`, `-3` before the extension, in date order, so
    /// the names are stable across exports of the same history.
    static func routeFileNames(for runs: [RunWorkout]) -> [UUID: String] {
        var names: [UUID: String] = [:]
        var used: [String: Int] = [:]
        for run in runs.sorted(by: { $0.date < $1.date }) where !run.routeCoordinates.isEmpty {
            let base = GPXExport.fileName(for: run)
            let count = (used[base] ?? 0) + 1
            used[base] = count
            if count == 1 {
                names[run.id] = base
            } else {
                let stem = base.hasSuffix(".gpx") ? String(base.dropLast(4)) : base
                names[run.id] = "\(stem)-\(count).gpx"
            }
        }
        return names
    }

    // MARK: - README

    static func readme(exportedAt: Date) -> String {
        """
        Stride data export
        Exported \(timestampString(exportedAt))

        runs.csv      Every workout Stride recorded or imported, one per row. The "type"
                      column separates runs from walks ("Walk") and cross-training
                      ("Cross Training"), which Stride keeps out of its running stats.
        strength.csv  Every strength session, one per row.
        shoes.csv     Every pair of shoes. A run's "shoe" column names the pair it was run in.
        routes/       One GPX file per outdoor workout with a GPS route. A run's
                      "route_file" column names its file.

        Units: distances in metres, durations in seconds, pace in seconds per kilometre,
        heart rate in beats per minute, cadence in steps per minute, temperature in Celsius.
        Times are UTC in ISO 8601. "feel" is how the run felt, 1 (very easy) to 5 (very hard).
        An empty cell means the value was never recorded.
        """
    }

    // MARK: - Formatting

    /// A fixed-decimal number through `en_US_POSIX`, so a German phone does not write
    /// `5000,0` into a comma-separated file.
    private static func number(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func optionalNumber(_ value: Double?, decimals: Int) -> String {
        value.map { number($0, decimals: decimals) } ?? ""
    }

    private static func timestampString(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// A date in the runner's own time zone — the one that makes a folder name or a shoe's
    /// start day recognisable.
    private static func localDateString(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

// MARK: - DataExportWriter

/// Writes `DataExport` entries to disk and zips them — the one part of the export that
/// touches the file system.
///
/// The zip comes from `NSFileCoordinator` reading a directory with `.forUploading`, which
/// Foundation documents as producing a zip archive of that directory. That keeps the app
/// free of a compression dependency for a feature used a handful of times a year.
enum DataExportWriter {

    enum WriteError: LocalizedError {
        case archiveFailed

        var errorDescription: String? {
            "Stride couldn't package your data. Please try again."
        }
    }

    /// Writes the archive to the temporary directory and returns its URL.
    ///
    /// The temporary directory for the reason `RunSummaryView.exportGPX` gives: the file
    /// exists only to be handed to the share sheet, and the system clears it. A leftover
    /// archive of the same name from an earlier export today is replaced.
    static func writeArchive(entries: [DataExport.Entry], name: String) throws -> URL {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DataExport-\(UUID().uuidString)", isDirectory: true)
        let folder = workDirectory.appendingPathComponent(name, isDirectory: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        for entry in entries {
            let url = folder.appendingPathComponent(entry.path)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.contents.write(to: url, atomically: true, encoding: .utf8)
        }

        let destination = fileManager.temporaryDirectory.appendingPathComponent("\(name).zip")
        var coordinationError: NSError?
        var copyError: Error?
        // The zipped URL handed to the accessor is only valid inside it, so the copy has to
        // happen there.
        NSFileCoordinator().coordinate(
            readingItemAt: folder,
            options: [.forUploading],
            error: &coordinationError
        ) { zippedURL in
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: zippedURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            AppLogger.log("Data export zip failed: \(error.localizedDescription)", label: "Export", level: .error)
            throw WriteError.archiveFailed
        }
        return destination
    }
}
