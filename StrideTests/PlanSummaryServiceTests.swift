import Foundation
import SwiftData
import Testing
@testable import Stride

@MainActor
struct PlanSummaryServiceTests {

    /// Builds a two-week plan: week 1 fully completed (easy run, tempo run,
    /// strength session, rest day), week 2 untouched (easy + long run).
    private func makePlan(in context: ModelContext) throws -> TrainingPlan {
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: start,
            endDate: start.addingTimeInterval(13 * 86_400)
        )
        plan.isActive = false
        context.insert(plan)

        let week1 = TrainingWeek(weekNumber: 1, startDate: start, phase: .base, targetDistanceKm: 13)
        let week2 = TrainingWeek(weekNumber: 2, startDate: start.addingTimeInterval(7 * 86_400), phase: .build, targetDistanceKm: 18)
        context.insert(week1)
        context.insert(week2)
        week1.plan = plan
        week2.plan = plan

        let easy1 = ScheduledWorkout(scheduledDate: start, workoutType: .easy, targetDistanceMeters: 5_000)
        let tempo = ScheduledWorkout(scheduledDate: start.addingTimeInterval(2 * 86_400), workoutType: .tempo, targetDistanceMeters: 8_000)
        let strength = ScheduledWorkout(scheduledDate: start.addingTimeInterval(4 * 86_400), workoutType: .strength)
        let rest = ScheduledWorkout(scheduledDate: start.addingTimeInterval(5 * 86_400), workoutType: .rest)
        let easy2 = ScheduledWorkout(scheduledDate: start.addingTimeInterval(7 * 86_400), workoutType: .easy, targetDistanceMeters: 6_000)
        let longRun = ScheduledWorkout(scheduledDate: start.addingTimeInterval(9 * 86_400), workoutType: .longRun, targetDistanceMeters: 12_000)

        for workout in [easy1, tempo, strength, rest, easy2, longRun] {
            context.insert(workout)
        }
        for workout in [easy1, tempo, strength, rest] { workout.week = week1 }
        for workout in [easy2, longRun] { workout.week = week2 }

        let easyRun = RunWorkout(date: start, distanceMeters: 5_000, durationSeconds: 1_500, workoutType: .easy)
        let tempoRun = RunWorkout(date: start.addingTimeInterval(2 * 86_400), distanceMeters: 8_000, durationSeconds: 2_520, workoutType: .tempo)
        context.insert(easyRun)
        context.insert(tempoRun)
        easy1.completedWorkout = easyRun
        easy1.isCompleted = true
        tempo.completedWorkout = tempoRun
        tempo.isCompleted = true

        let strengthSession = StrengthWorkout(date: start.addingTimeInterval(4 * 86_400), durationSeconds: 1_800)
        context.insert(strengthSession)
        strength.completedStrengthWorkout = strengthSession
        strength.isCompleted = true

        try context.save()
        return plan
    }

    @Test("Summary aggregates completed workouts, distance, time, and pace")
    func summaryAggregatesCompletedWork() throws {
        let container = AppContainer.preview()
        let plan = try makePlan(in: container.modelContainer.mainContext)

        let summary = PlanSummaryService.summary(for: plan)

        // Rest days are excluded from adherence.
        #expect(summary.scheduledCount == 5)
        #expect(summary.completedCount == 3)
        #expect(abs(summary.adherence - 0.6) < 0.0001)

        #expect(summary.completedRunCount == 2)
        #expect(summary.completedStrengthCount == 1)
        #expect(summary.completedDistanceMeters == 13_000)
        #expect(summary.targetDistanceMeters == 31_000)
        #expect(summary.totalDurationSeconds == 1_500 + 2_520 + 1_800)
        #expect(summary.longestRunMeters == 8_000)

        // Distance-weighted pace: (1500 + 2520) s over 13 km.
        let expectedPace = 4_020.0 / 13_000.0 * 1_000.0
        let pace = try #require(summary.averagePaceSecondsPerKm)
        #expect(abs(pace - expectedPace) < 0.01)

        // Week 1's non-rest workouts are all completed; week 2's are not.
        #expect(summary.weeksCompleted == 1)
        #expect(summary.totalWeeks == 2)
    }

    @Test("Summary breaks down completion per workout type")
    func summaryTypeBreakdown() throws {
        let container = AppContainer.preview()
        let plan = try makePlan(in: container.modelContainer.mainContext)

        let summary = PlanSummaryService.summary(for: plan)
        let byType = Dictionary(uniqueKeysWithValues: summary.typeBreakdown.map { ($0.type, $0) })

        #expect(byType[.rest] == nil)
        #expect(byType[.easy]?.scheduled == 2)
        #expect(byType[.easy]?.completed == 1)
        #expect(byType[.tempo]?.scheduled == 1)
        #expect(byType[.tempo]?.completed == 1)
        #expect(byType[.strength]?.completed == 1)
        #expect(byType[.longRun]?.completed == 0)

        // Most-scheduled type comes first.
        #expect(summary.typeBreakdown.first?.type == .easy)
    }

    @Test("Summary of an empty plan reports zeros without dividing by zero")
    func summaryHandlesEmptyPlan() throws {
        let container = AppContainer.preview()
        let context = container.modelContainer.mainContext

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: start,
            endDate: start.addingTimeInterval(7 * 86_400)
        )
        context.insert(plan)
        try context.save()

        let summary = PlanSummaryService.summary(for: plan)
        #expect(summary.scheduledCount == 0)
        #expect(summary.adherence == 0)
        #expect(summary.averagePaceSecondsPerKm == nil)
        #expect(summary.longestRunMeters == 0)
        #expect(summary.typeBreakdown.isEmpty)
    }

    @Test("Plan status derives from isActive and the end date")
    func statusDerivation() throws {
        let container = AppContainer.preview()
        let context = container.modelContainer.mainContext

        let now = Date(timeIntervalSince1970: 1_705_000_000)
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: now.addingTimeInterval(-14 * 86_400),
            endDate: now.addingTimeInterval(-1 * 86_400)
        )
        context.insert(plan)

        plan.isActive = true
        #expect(PlanSummaryService.status(of: plan, now: now) == .active)

        // Inactive with the end date in the past → finished.
        plan.isActive = false
        #expect(PlanSummaryService.status(of: plan, now: now) == .finished)

        // Inactive but replaced before its end date → ended.
        plan.endDate = now.addingTimeInterval(7 * 86_400)
        #expect(PlanSummaryService.status(of: plan, now: now) == .ended)
    }
}
