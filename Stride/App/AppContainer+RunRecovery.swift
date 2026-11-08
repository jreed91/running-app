import Foundation
import SwiftData

extension AppContainer {

    /// Saves a run the app was killed in the middle of, from the tracker's last checkpoint,
    /// and shows it for review (P1.2).
    ///
    /// The run used to live only in `WorkoutTrackerService`'s memory, so a long run the
    /// system killed for memory, a crash, or a force quit lost all of it. The tracker now
    /// writes a ``RunCheckpoint`` every half minute and on pause; this saves the last one
    /// the way `ActiveRunView` saves a finished run: the default shoe, the planned session
    /// it completes, Apple Health, the weather, and the pace refresh. It ends where the
    /// checkpoint did, so up to ``WorkoutTrackerService/checkpointInterval`` seconds of the
    /// run are missing, and the run's note says so.
    ///
    /// Called once at launch, before anything else can start a run.
    func recoverInterruptedRun(from url: URL = RunCheckpointStore.defaultURL) {
        // A run in this same process is still being recorded, not interrupted.
        guard !workoutTrackerService.isRecording,
              let checkpoint = RunCheckpointStore.load(from: url)
        else { return }
        // Cleared before anything else, so a recovery that crashes cannot crash every
        // launch after it. A failed save puts it back below.
        RunCheckpointStore.clear(at: url)

        let context = modelContainer.mainContext
        let runID = checkpoint.runID
        let alreadySaved = ((try? context.fetchCount(
            FetchDescriptor<RunWorkout>(predicate: #Predicate { $0.id == runID })
        )) ?? 0) > 0
        guard checkpoint.isWorthRecovering, !alreadySaved else {
            AppLogger.log(
                "Dropped a run checkpoint (saved already: \(alreadySaved), "
                    + "\(Int(checkpoint.distanceMeters)) m / \(Int(checkpoint.elapsedSeconds)) s)",
                label: "ActiveRun"
            )
            return
        }

        let workout = checkpoint.makeWorkout()
        workout.notes = String(
            localized: "Stride closed during this run, so it ends at the last point it saved.",
            comment: "Note on a run recovered after the app closed mid-run"
        )
        context.insert(workout)
        ShoeAssignment.assignDefaultShoe(to: [workout], in: context)
        // The screen that knew which session this was went with the process, so the run is
        // matched to its day the way an imported one is.
        workoutSyncService.linkToScheduledWorkouts([workout])
        do {
            try context.save()
        } catch {
            context.rollback()
            RunCheckpointStore.save(checkpoint, to: url)
            AppLogger.log(
                "Couldn't save the recovered run \(runID); kept its checkpoint for the next launch: "
                    + error.localizedDescription,
                label: "ActiveRun",
                level: .error
            )
            return
        }
        AppLogger.log(
            "Recovered run \(runID) from its checkpoint "
                + "(\(Int(checkpoint.distanceMeters)) m / \(Int(checkpoint.elapsedSeconds)) s)",
            label: "ActiveRun",
            level: .info
        )

        let healthKit = healthKitRepository
        Task { @MainActor in
            if let hkID = try? await healthKit.save(workout) {
                workout.healthKitWorkoutID = hkID
                context.saveOrLog("the recovered run's HealthKit id")
            }
        }
        if let coordinate = workout.routeCoordinates.first {
            Task { await attachWeather(to: workout, coordinate: coordinate) }
        }
        planLifecycle.refreshPlanAfterImport(context: context, unitPreference: AppSettings.syncedUnitPreference())
        pendingReviewWorkout = workout
    }
}
