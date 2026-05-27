import Foundation

// MARK: - StravaGPXBuilder

/// Builds a minimal GPX 1.1 track from a completed run so it can be uploaded to Strava.
///
/// `RunWorkout` stores only an ordered list of coordinates (no per-point timestamps),
/// so timestamps are synthesised by spreading the run's total duration evenly across the
/// track points. This is enough for Strava to render the route map and derive distance,
/// time, and average pace.
enum StravaGPXBuilder {

    /// Returns GPX data for the run, or `nil` when there is no usable GPS route.
    static func makeGPX(for workout: RunWorkout) -> Data? {
        let coordinates = workout.routeCoordinates
        guard coordinates.count >= 2 else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")

        let start = workout.date
        let duration = max(workout.durationSeconds, 0)
        let lastIndex = Double(coordinates.count - 1)

        var points = ""
        for (index, coordinate) in coordinates.enumerated() {
            let fraction = lastIndex > 0 ? Double(index) / lastIndex : 0
            let time = start.addingTimeInterval(duration * fraction)
            points += """
                  <trkpt lat="\(coordinate.latitude)" lon="\(coordinate.longitude)">
                    <time>\(formatter.string(from: time))</time>
                  </trkpt>

            """
        }

        let name = escape("\(workout.workoutType.displayName) Run")
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Stride" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <time>\(formatter.string(from: start))</time>
          </metadata>
          <trk>
            <name>\(name)</name>
            <type>running</type>
            <trkseg>
        \(points)    </trkseg>
          </trk>
        </gpx>
        """
        return gpx.data(using: .utf8)
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
