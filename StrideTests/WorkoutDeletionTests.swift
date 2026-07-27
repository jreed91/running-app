import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers the single repository deletion path that owns cross-cutting invariants:
/// tombstone creation (H9) and scheduled-day reset (M20), for both runs and strength.
@MainActor
struct WorkoutDeletionTests {

    private func makeContainer() -> AppContainer { TestStore.makeContainer() }

    @Test("Deleting a linked run resets the scheduled day and writes a tombstone")
    func deletingRunResetsScheduledAndTombstones() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext

        let scheduled = ScheduledWorkout(scheduledDate: .now, workoutType: .tempo)
        let run = RunWorkout(distanceMeters: 8_000, durationSeconds: 2_400, workoutType: .tempo)
        run.healthKitWorkoutID = "HK-RUN-1"

        // Simulate a completed link.
        run.scheduledWorkout = scheduled
        scheduled.completedWorkout = run
        scheduled.isCompleted = true
        scheduled.linkedRunWorkoutID = run.id
        run.linkedScheduledWorkoutID = scheduled.id

        context.insert(scheduled)
        context.insert(run)
        try context.save()

        try container.workoutRepository.delete(run)

        // Scheduled day is no longer marked complete and is unlinked.
        #expect(scheduled.isCompleted == false)
        #expect(scheduled.completedWorkout == nil)
        #expect(scheduled.linkedRunWorkoutID == nil)

        // A tombstone now blocks re-import of the HealthKit source.
        let tombstones = try context.fetch(FetchDescriptor<DeletedWorkout>())
        #expect(tombstones.contains { $0.healthKitWorkoutID == "HK-RUN-1" })

        // The run itself is gone.
        let runs = try context.fetch(FetchDescriptor<RunWorkout>())
        #expect(runs.isEmpty)
    }

    @Test("Deleting a run without a HealthKit ID writes no tombstone")
    func deletingManualRunSkipsTombstone() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext

        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_500)
        context.insert(run)
        try context.save()

        try container.workoutRepository.delete(run)

        let tombstones = try context.fetch(FetchDescriptor<DeletedWorkout>())
        #expect(tombstones.isEmpty)
    }

    @Test("Deleting a strength workout resets the scheduled day and writes a tombstone")
    func deletingStrengthResetsScheduledAndTombstones() throws {
        let container = makeContainer()
        let context = container.modelContainer.mainContext

        let scheduled = ScheduledWorkout(scheduledDate: .now, workoutType: .strength)
        let strength = StrengthWorkout(date: .now, durationSeconds: 1_800)
        strength.healthKitWorkoutID = "HK-STR-1"

        strength.scheduledWorkout = scheduled
        scheduled.completedStrengthWorkout = strength
        scheduled.isCompleted = true
        scheduled.linkedStrengthWorkoutID = strength.id
        strength.linkedScheduledWorkoutID = scheduled.id

        context.insert(scheduled)
        context.insert(strength)
        try context.save()

        try container.workoutRepository.delete(strength)

        #expect(scheduled.isCompleted == false)
        #expect(scheduled.completedStrengthWorkout == nil)
        #expect(scheduled.linkedStrengthWorkoutID == nil)

        let tombstones = try context.fetch(FetchDescriptor<DeletedWorkout>())
        #expect(tombstones.contains { $0.healthKitWorkoutID == "HK-STR-1" })

        let strengthWorkouts = try context.fetch(FetchDescriptor<StrengthWorkout>())
        #expect(strengthWorkouts.isEmpty)
    }

    @Test("isRunType only accepts run workout types")
    func isRunTypeClassification() {
        #expect(WorkoutType.easy.isRunType)
        #expect(WorkoutType.tempo.isRunType)
        #expect(WorkoutType.interval.isRunType)
        #expect(WorkoutType.longRun.isRunType)
        #expect(WorkoutType.race.isRunType)

        #expect(!WorkoutType.rest.isRunType)
        #expect(!WorkoutType.crossTraining.isRunType)
        #expect(!WorkoutType.strength.isRunType)
    }
}
