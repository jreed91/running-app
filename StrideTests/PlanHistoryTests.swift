import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers the plan-history-preservation invariants behind H3: a plan with completed
/// work must be recognisable as history (`hasLoggedProgress`) so plan creation
/// deactivates rather than deletes it, and the repository must keep exactly one
/// active plan.
@MainActor
struct PlanHistoryTests {

    private func makePlan(
        in context: ModelContext,
        completeFirstWorkout: Bool,
        isActive: Bool = false
    ) throws -> TrainingPlan {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: start,
            endDate: start.addingTimeInterval(6 * 86_400)
        )
        plan.isActive = isActive
        context.insert(plan)

        let week = TrainingWeek(weekNumber: 1, startDate: start, phase: .base, targetDistanceKm: 13)
        context.insert(week)
        week.plan = plan

        let easy = ScheduledWorkout(scheduledDate: start, workoutType: .easy, targetDistanceMeters: 5_000)
        let rest = ScheduledWorkout(scheduledDate: start.addingTimeInterval(86_400), workoutType: .rest)
        context.insert(easy)
        context.insert(rest)
        easy.week = week
        rest.week = week

        if completeFirstWorkout {
            let run = RunWorkout(date: start, distanceMeters: 5_000, durationSeconds: 1_500, workoutType: .easy)
            context.insert(run)
            easy.completedWorkout = run
            easy.isCompleted = true
        }

        try context.save()
        return plan
    }

    @Test("hasLoggedProgress is true only once a non-rest workout is completed")
    func hasLoggedProgressReflectsCompletion() throws {
        let context = AppContainer.preview().modelContainer.mainContext

        let untouched = try makePlan(in: context, completeFirstWorkout: false)
        #expect(untouched.hasLoggedProgress == false)

        let started = try makePlan(in: context, completeFirstWorkout: true)
        #expect(started.hasLoggedProgress == true)
    }

    @Test("A completed rest day does not count as logged progress")
    func restCompletionIsNotProgress() throws {
        let context = AppContainer.preview().modelContainer.mainContext
        let plan = try makePlan(in: context, completeFirstWorkout: false)

        // Mark only the rest day complete.
        let workouts = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }
        workouts.first { $0.workoutType == .rest }?.isCompleted = true
        try context.save()

        #expect(plan.hasLoggedProgress == false)
    }

    @Test("Saving an active plan deactivates every other plan")
    func saveEnforcesSingleActivePlan() throws {
        let container = AppContainer.preview()
        let context = container.modelContainer.mainContext

        let old = try makePlan(in: context, completeFirstWorkout: true, isActive: true)
        #expect(old.isActive == true)

        let new = TrainingPlan(
            targetRace: .halfMarathon,
            goalTimeSeconds: 5_400,
            startDate: Date(),
            endDate: Date().addingTimeInterval(6 * 86_400)
        ) // init sets isActive = true
        try container.planRepository.save(new)

        #expect(new.isActive == true)
        #expect(old.isActive == false)

        let actives = try context.fetch(
            FetchDescriptor<TrainingPlan>(predicate: #Predicate { $0.isActive })
        )
        #expect(actives.count == 1)
        #expect(actives.first?.id == new.id)
    }

    @Test("fetchActivePlan returns the most recently created active plan")
    func fetchActivePlanIsDeterministic() throws {
        let container = AppContainer.preview()
        let context = container.modelContainer.mainContext

        // Force a violated invariant: two actives with different creation dates.
        let older = try makePlan(in: context, completeFirstWorkout: false, isActive: true)
        older.createdAt = Date(timeIntervalSince1970: 1_000)
        let newer = try makePlan(in: context, completeFirstWorkout: false, isActive: true)
        newer.createdAt = Date(timeIntervalSince1970: 2_000)
        try context.save()

        let resolved = try container.planRepository.fetchActivePlan()
        #expect(resolved?.id == newer.id)
    }
}
