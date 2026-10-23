import Foundation
@preconcurrency import WorkoutKit

// MARK: - Single-workout WorkoutKit sync

// Kept apart from `HealthKitRepository.swift`, which is at the file-length limit.
extension HealthKitRepository {

    @MainActor func syncWorkoutPlan(for workout: ScheduledWorkout, unitPreference: UnitPreference) async throws {
        guard WorkoutScheduler.isSupported else {
            throw HealthKitRepositoryError.workoutKitUnsupported
        }
        let scheduler = WorkoutScheduler.shared
        guard await scheduler.authorizationState == .authorized else {
            throw HealthKitRepositoryError.workoutKitNotAuthorized
        }

        let ids = Self.workoutKitPlanIDs(for: workout)
        let scheduled = await scheduler.scheduledWorkouts
        for entry in scheduled where ids.contains(entry.plan.id.uuidString) {
            await scheduler.remove(entry.plan, at: entry.date)
        }
        workout.healthKitPlanID = nil

        guard workout.workoutType != .rest, !workout.isCompleted,
              let fireDate = Self.workoutKitFireDate(for: workout.scheduledDate, now: Date())
        else { return }
        let dateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let workoutPlan = Self.makeWorkoutPlan(for: workout, unitPreference: unitPreference)
        await scheduler.schedule(workoutPlan, at: dateComponents)
        workout.healthKitPlanID = workoutPlan.id.uuidString
    }

    /// Every id a workout's WorkoutKit composition may be filed under: its own id, which
    /// ``makeWorkoutPlan(for:unitPreference:)`` uses, plus whatever an earlier sync
    /// recorded — the same pair ``syncWorkoutPlans(for:unitPreference:)`` clears.
    static func workoutKitPlanIDs(for workout: ScheduledWorkout) -> Set<String> {
        var ids: Set<String> = [workout.id.uuidString]
        if let recorded = workout.healthKitPlanID { ids.insert(recorded) }
        return ids
    }
}
