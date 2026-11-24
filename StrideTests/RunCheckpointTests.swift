import CoreLocation
import Foundation
import Testing
@testable import Stride

/// The checkpoint an app killed mid-run is recovered from (P1.2).
struct RunCheckpointTests {

    private func sample(distance: Double = 5_200, elapsed: Double = 1_560) -> RunCheckpoint {
        RunCheckpoint(
            runID: UUID(),
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            savedAt: Date(timeIntervalSince1970: 1_800_001_560),
            workoutType: .tempo,
            workoutLocation: .outdoor,
            splitUnitRaw: UnitPreference.imperial.rawValue,
            elapsedSeconds: elapsed,
            distanceMeters: distance,
            coordinates: [
                Coordinate(CLLocationCoordinate2D(latitude: 41.88, longitude: -87.63)),
                Coordinate(CLLocationCoordinate2D(latitude: 41.89, longitude: -87.62))
            ],
            splits: [
                Split(
                    kilometer: 1,
                    paceSecondsPerKm: 300,
                    heartRate: 150,
                    elevationGainMeters: 4,
                    cumulativeDistanceMeters: 1_609.344
                )
            ],
            distanceSeries: [
                SplitBucketing.DistancePoint(elapsedSeconds: 480, cumulativeMeters: 1_609, altitudeMeters: 180)
            ],
            lapMarks: [LapRecorder.Mark(elapsedSeconds: 600, distanceMeters: 2_000)],
            elevationGainMeters: 12,
            cadenceSamples: [170, 174],
            heartRateSamples: [140, 160]
        )
    }

    @Test("A checkpoint survives a round trip through the file")
    func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "run-checkpoint-\(UUID().uuidString)/in-progress-run.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let checkpoint = sample()

        RunCheckpointStore.save(checkpoint, to: url)
        #expect(RunCheckpointStore.load(from: url) == checkpoint)

        RunCheckpointStore.clear(at: url)
        #expect(RunCheckpointStore.load(from: url) == nil)
    }

    @Test("The recovered run keeps its id, its data, and closes the lap it was in")
    func makeWorkoutCarriesEverything() {
        let checkpoint = sample()
        let workout = checkpoint.makeWorkout()

        #expect(workout.id == checkpoint.runID)
        #expect(workout.date == checkpoint.startDate)
        #expect(workout.distanceMeters == 5_200)
        #expect(workout.durationSeconds == 1_560)
        #expect(workout.workoutType == .tempo)
        #expect(workout.splitUnit == .imperial)
        #expect(workout.routeCoordinates.count == 2)
        #expect(workout.splits == checkpoint.splits)
        #expect(workout.distanceSeries == checkpoint.distanceSeries)
        // One tap plus the lap the run ended in.
        #expect(workout.laps.count == 2)
        #expect(workout.elevationGainMeters == 12)
        #expect(workout.averageCadenceStepsPerMinute == 172)
        #expect(workout.averageHeartRate == 150)
        #expect(workout.maxHeartRate == 160)
    }

    @Test("A checkpoint from a mis-tap is not worth recovering")
    func misTapIsDropped() {
        #expect(sample().isWorthRecovering)
        #expect(!sample(distance: 40, elapsed: 20).isWorthRecovering)
    }
}
