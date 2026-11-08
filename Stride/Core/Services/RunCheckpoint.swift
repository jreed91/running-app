import Foundation

// MARK: - RunCheckpoint

/// Everything a run in progress has recorded so far, as a value.
///
/// The live run used to exist only in `WorkoutTrackerService`'s memory, so an app the
/// system killed mid-run (memory pressure on a long run, a crash, a force quit) took the
/// whole run with it (P1.2). The tracker now writes one of these to disk every
/// ``WorkoutTrackerService/checkpointInterval`` seconds and on pause, and
/// `AppContainer.recoverInterruptedRun()` saves the last one on the next launch.
///
/// ``makeWorkout()`` is also how the tracker builds the run it returns from
/// `finishWorkout()`, so a recovered run is put together by the same code as a finished
/// one and the two cannot drift apart.
struct RunCheckpoint: Codable, Equatable, Sendable {
    /// The id the finished run is saved under. Fixed at the start, so a run that was both
    /// saved and recovered is the same row rather than two.
    var runID: UUID
    var startDate: Date
    /// When this checkpoint was taken. A recovered run ends here.
    var savedAt: Date
    var workoutType: WorkoutType
    var workoutLocation: WorkoutLocation
    /// `UnitPreference` is not `Codable`; its raw value is.
    var splitUnitRaw: String
    var elapsedSeconds: Double
    var distanceMeters: Double
    var coordinates: [Coordinate]
    var splits: [Split]
    var distanceSeries: [SplitBucketing.DistancePoint]
    var lapMarks: [LapRecorder.Mark]
    var elevationGainMeters: Double
    var cadenceSamples: [Double]
    var heartRateSamples: [Double]

    /// The run as it stood when this checkpoint was taken, unsaved.
    func makeWorkout() -> RunWorkout {
        let workout = RunWorkout(
            date: startDate,
            distanceMeters: distanceMeters,
            durationSeconds: elapsedSeconds,
            workoutType: workoutType,
            workoutLocation: workoutLocation
        )
        workout.id = runID
        workout.routeCoordinates = coordinates
        workout.splits = splits
        workout.splitUnit = UnitPreference(rawValue: splitUnitRaw) ?? .metric
        workout.distanceSeries = distanceSeries
        // The final lap is closed by the finish itself, so the run keeps every boundary the
        // runner marked rather than losing the one they were in when they stopped (A2).
        workout.laps = LapRecorder.laps(
            marks: lapMarks,
            finish: LapRecorder.Mark(elapsedSeconds: elapsedSeconds, distanceMeters: distanceMeters)
        )
        if elevationGainMeters > 0 {
            workout.elevationGainMeters = elevationGainMeters
        }
        if !cadenceSamples.isEmpty {
            workout.averageCadenceStepsPerMinute = cadenceSamples.reduce(0, +) / Double(cadenceSamples.count)
        }
        if !heartRateSamples.isEmpty {
            workout.averageHeartRate = heartRateSamples.reduce(0, +) / Double(heartRateSamples.count)
            workout.maxHeartRate = heartRateSamples.max()
            // Persist the raw series so the time-in-zone breakdown can be computed for
            // app-recorded runs (A6).
            workout.heartRateSamples = heartRateSamples
        }
        return workout
    }

    /// Whether this is worth saving as a run at all. A checkpoint taken a few seconds
    /// after Start is a mis-tap by the same rule the finished run is held to (N17).
    var isWorthRecovering: Bool {
        RunEffortPolicy.isRealRun(distanceMeters: distanceMeters, durationSeconds: elapsedSeconds)
    }
}

// MARK: - RunCheckpointStore

/// The one checkpoint on disk.
///
/// A file in Application Support rather than `UserDefaults`: a checkpoint carries the
/// route, and full location traces in the defaults plist were the privacy problem S3
/// removed from the review snapshot. Binary property list, because it is rewritten every
/// half minute on the main actor and a marathon's route is thousands of points.
enum RunCheckpointStore {

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "in-progress-run.plist")
    }

    static func save(_ checkpoint: RunCheckpoint, to url: URL = defaultURL) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            let data = try encoder.encode(checkpoint)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Writable while the phone is locked, which is most of a run.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            AppLogger.log(
                "Couldn't write the run checkpoint: \(error.localizedDescription)",
                label: "WorkoutTrackerService",
                level: .error
            )
        }
    }

    static func load(from url: URL = defaultURL) -> RunCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(RunCheckpoint.self, from: data)
    }

    static func clear(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
