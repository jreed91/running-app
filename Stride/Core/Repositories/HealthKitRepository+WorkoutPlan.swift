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
        var removed = 0
        for entry in scheduled where ids.contains(entry.plan.id.uuidString) {
            await scheduler.remove(entry.plan, at: entry.date)
            removed += 1
        }
        workout.healthKitPlanID = nil

        // A session outside the Workout app's window (the full sync files only the soonest
        // `maxAllowedScheduledWorkoutCount`) stays out: the scheduler would drop it anyway,
        // and the next full sync adds it once it is among the soonest.
        guard workout.workoutType != .rest, !workout.isCompleted,
              scheduled.count - removed < WorkoutScheduler.maxAllowedScheduledWorkoutCount,
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

    /// The workouts a full sync files with the Workout app, soonest first, each with the
    /// instant it is filed under: rest days, completed sessions and past days are left out,
    /// and only the first `limit` are kept.
    ///
    /// The Workout app takes at most `WorkoutScheduler.maxAllowedScheduledWorkoutCount`
    /// workouts from one app. A plan has far more, and `plan.weeks` comes back from
    /// SwiftData in no set order, so scheduling every session let the cap fill with weeks
    /// far ahead and drop this week's. Sorting by date keeps the next sessions on the Watch.
    static func workoutKitSchedule(
        for workouts: [ScheduledWorkout],
        now: Date,
        calendar: Calendar = .current,
        limit: Int
    ) -> [(workout: ScheduledWorkout, fireDate: Date)] {
        let dated: [(workout: ScheduledWorkout, fireDate: Date)] = workouts.compactMap { workout in
            guard workout.workoutType != .rest, !workout.isCompleted,
                  let fireDate = workoutKitFireDate(for: workout.scheduledDate, now: now, calendar: calendar)
            else { return nil }
            return (workout, fireDate)
        }
        let soonestFirst = dated.sorted { lhs, rhs in
            if lhs.workout.scheduledDate != rhs.workout.scheduledDate {
                return lhs.workout.scheduledDate < rhs.workout.scheduledDate
            }
            return lhs.workout.id.uuidString < rhs.workout.id.uuidString
        }
        return Array(soonestFirst.prefix(max(limit, 0)))
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
