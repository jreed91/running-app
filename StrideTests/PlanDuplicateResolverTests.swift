import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers N6: same-day duplicate pruning must compare like with like. Grouping a
/// day's workouts together regardless of kind meant Smart Adapt deleted the
/// runner's strength session whenever a run had been shifted onto that day.
@MainActor
struct PlanDuplicateResolverTests {

    private let day = Date(timeIntervalSince1970: 1_700_000_000).startOfDay

    private func workout(
        _ type: WorkoutType,
        onDayOffset offset: Int = 0,
        completed: Bool = false
    ) -> ScheduledWorkout {
        let workout = ScheduledWorkout(
            scheduledDate: day.adding(days: offset),
            workoutType: type
        )
        workout.isCompleted = completed
        return workout
    }

    @Test("A run and a strength session on the same day are both kept")
    func runAndStrengthCoexist() {
        let run = workout(.easy)
        let strength = workout(.strength)

        let redundant = PlanDuplicateResolver.redundantWorkouts(in: [run, strength])

        #expect(redundant.isEmpty)
    }

    @Test("Two runs on the same day collapse to the more specific session")
    func duplicateRunsCollapse() {
        let easy = workout(.easy)
        let tempo = workout(.tempo)

        let redundant = PlanDuplicateResolver.redundantWorkouts(in: [easy, tempo])

        #expect(redundant.count == 1)
        #expect(redundant.first?.id == easy.id)
    }

    @Test("Two strength sessions on the same day collapse to one")
    func duplicateStrengthCollapses() {
        let first = workout(.strength)
        let second = workout(.strength)

        let redundant = PlanDuplicateResolver.redundantWorkouts(in: [first, second])

        #expect(redundant.count == 1)
    }

    @Test("A completed workout always survives its duplicates")
    func completedWorkoutSurvives() {
        let completedEasy = workout(.easy, completed: true)
        let plannedLongRun = workout(.longRun)

        let redundant = PlanDuplicateResolver.redundantWorkouts(in: [completedEasy, plannedLongRun])

        #expect(redundant.count == 1)
        #expect(redundant.first?.id == plannedLongRun.id)
    }

    @Test("Workouts on different days are never duplicates")
    func differentDaysAreNotDuplicates() {
        let monday = workout(.easy, onDayOffset: 0)
        let tuesday = workout(.easy, onDayOffset: 1)

        #expect(PlanDuplicateResolver.redundantWorkouts(in: [monday, tuesday]).isEmpty)
    }

    @Test("A full shifted week keeps every strength day")
    func shiftedWeekKeepsStrength() {
        // The shape "pick up where I left off" used to produce: runs moved onto the
        // days the gym sessions already occupied.
        let workouts = [
            workout(.easy, onDayOffset: 0), workout(.strength, onDayOffset: 0),
            workout(.tempo, onDayOffset: 2), workout(.strength, onDayOffset: 2),
            workout(.longRun, onDayOffset: 5)
        ]

        let redundant = PlanDuplicateResolver.redundantWorkouts(in: workouts)

        #expect(redundant.isEmpty)
        #expect(workouts.filter { $0.workoutType == .strength }.count == 2)
    }

    @Test("Cross-training and rest are their own kinds")
    func crossTrainingAndRestAreDistinctKinds() {
        let run = workout(.easy)
        let cross = workout(.crossTraining)
        let rest = workout(.rest)

        #expect(PlanDuplicateResolver.redundantWorkouts(in: [run, cross, rest]).isEmpty)
    }
}
