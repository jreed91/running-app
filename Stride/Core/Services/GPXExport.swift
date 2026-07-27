import Foundation

/// Builds a GPX 1.1 document from a completed run so its route can leave the app (B6).
///
/// Runs were a one-way trip: HealthKit imports in, CloudKit syncs between the runner's own
/// devices, and nothing at all comes out in a format another tool reads. GPX is the format
/// every route tool — Strava, Garmin Connect, Komoot, a spreadsheet — takes, and the app
/// already stores everything it needs.
///
/// Pure string building with no UI and no file system, so the document can be asserted on
/// directly; `RunSummaryView` writes it to a temporary file at the moment the runner asks
/// to share it.
enum GPXExport {

    /// The GPX document for a run, or `nil` when the run has no route to export — indoor
    /// runs and any outdoor run that never got a usable fix. Those runs offer no export
    /// rather than exporting an empty track.
    static func document(for workout: RunWorkout, creator: String = "Stride") -> String? {
        let coordinates = workout.routeCoordinates
        guard !coordinates.isEmpty else { return nil }

        let start = workout.date
        let end = start.addingTimeInterval(max(0, workout.durationSeconds))
        return document(
            coordinates: coordinates,
            // The route is stored as a bare ordered coordinate array with no timestamps of
            // its own, so points are laid back onto the run's timeline evenly — the same
            // assumption `HealthKitRepository.saveRoute` already makes when it writes this
            // very trace to HealthKit. Reused rather than restated, so an exported file and
            // the Health copy of the same run agree about when the runner was where.
            timestamps: HealthKitRepository.sampleTimestamps(
                count: coordinates.count, start: start, end: end
            ),
            name: trackName(for: workout),
            startedAt: start,
            creator: creator
        )
    }

    /// The document itself, from a route and the times its points were reached.
    ///
    /// Split from the `RunWorkout` overload above so the XML — which is the part with a
    /// specification to conform to — can be asserted without a SwiftData model or a
    /// HealthKit store behind it.
    static func document(
        coordinates: [Coordinate],
        timestamps: [Date],
        name: String,
        startedAt: Date,
        creator: String = "Stride"
    ) -> String? {
        guard !coordinates.isEmpty, timestamps.count == coordinates.count else { return nil }

        let trackPoints = zip(coordinates, timestamps).map { coordinate, timestamp -> String in
            let lat = coordinateString(coordinate.latitude)
            let lon = coordinateString(coordinate.longitude)
            return "      <trkpt lat=\"\(lat)\" lon=\"\(lon)\">\n"
                + "        <time>\(timestampString(timestamp))</time>\n"
                + "      </trkpt>"
        }
        let points = trackPoints.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="\(escaped(creator))" xmlns="http://www.topografix.com/GPX/1/1" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
        xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(escaped(name))</name>
            <time>\(timestampString(startedAt))</time>
          </metadata>
          <trk>
            <name>\(escaped(name))</name>
            <type>running</type>
            <trkseg>
        \(points)
            </trkseg>
          </trk>
        </gpx>
        """
    }

    /// File name for the exported document, e.g. `Stride-Easy-Run-2026-07-26-0730.gpx`.
    ///
    /// Dated and typed rather than named after the run's id: the file lands in the
    /// runner's Files app or an email attachment, where a UUID tells them nothing about
    /// which run it is.
    static func fileName(for workout: RunWorkout) -> String {
        let type = workout.workoutType.displayName
            .replacingOccurrences(of: " ", with: "-")
        return "Stride-\(type)-\(localDateString(workout.date, format: "yyyy-MM-dd-HHmm")).gpx"
    }

    // MARK: - Private

    /// The track's name, e.g. `Tempo run — 2027-01-15 08:00`.
    ///
    /// Every part of it is deliberately locale-stable: `displayName` rather than
    /// `localizedName`, and a fixed date pattern rather than `formatted(date:time:)`. This
    /// string is read by whatever tool imports the file, not by the runner (per AGENTS.md),
    /// and two exports of the same run should not differ because the phone's language
    /// changed in between.
    private static func trackName(for workout: RunWorkout) -> String {
        let date = localDateString(workout.date, format: "yyyy-MM-dd HH:mm")
        return "\(workout.workoutType.displayName) run — \(date)"
    }

    /// A fixed-pattern date in the runner's own time zone — which is the one they ran in,
    /// and so the one that makes a file name and a track title recognisable. The instant
    /// itself is still written in UTC inside the document, where the schema requires it.
    private static func localDateString(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Fixed six-decimal degrees (~11 cm), locale-independent. `String(describing:)` on a
    /// `Double` would emit whatever the current locale uses for a decimal separator, and a
    /// GPX with `lat="52,3"` fails to parse everywhere.
    private static func coordinateString(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// ISO 8601 in UTC, which is the only form the GPX schema accepts.
    private static func timestampString(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// XML-escapes the five reserved characters. Only the run's type and date reach a text
    /// node today, but a plan's race name is one refactor away from doing so.
    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
