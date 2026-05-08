import Testing
import Foundation
@testable import Stride

struct MissedWorkoutDetectorTests {

    private let detector = MissedWorkoutDetector()
    private let service = TrainingPlanService()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
    }

    private func makePlan(startDate: Date, runDays: Int = 4) -> TrainingPlan {
        let profile = UserProfile(
            name: "Test",
            goalRace: .halfMarathon,
            goalFinishTime: 90 * 60,
            weeklyRunDays: runDays,
            fitnessLevel: .intermediate
        )
        return service.generatePlan(profile: profile, startDate: startDate, numberOfWeeks: 8)
    }

    /// Non-rest past workouts sorted ascending.
    private func pastNonRest(in plan: TrainingPlan, before today: Date) -> [ScheduledWorkout] {
        (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter {
                $0.scheduledDate < today
                    && $0.workoutType != .rest
                    && $0.workoutType != .strength
                    && $0.workoutType != .crossTraining
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    // MARK: Edge cases

    @Test("Empty plan returns nil")
    func emptyPlanReturnsNil() {
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_200,
            startDate: date(2026, 4, 1),
            endDate: date(2026, 5, 1)
        )
        let result = detector.detect(in: plan, today: date(2026, 5, 1))
        #expect(result == nil)
    }

    @Test("Future-only plan returns nil")
    func futurePlanReturnsNil() {
        let plan = makePlan(startDate: date(2026, 5, 10))
        let result = detector.detect(in: plan, today: date(2026, 5, 8))
        #expect(result == nil)
    }

    // MARK: Threshold

    @Test("All past workouts completed returns nil")
    func allCompletedReturnsNil() {
        let plan = makePlan(startDate: date(2026, 4, 1))
        let today = date(2026, 5, 1)
        pastNonRest(in: plan, before: today).forEach { $0.isCompleted = true }

        let result = detector.detect(in: plan, today: today)
        #expect(result == nil)
    }

    @Test("One trailing missed workout does not trigger — threshold is 2")
    func oneMissedBelowThreshold() {
        let plan = makePlan(startDate: date(2026, 4, 1))
        let today = date(2026, 5, 1)
        let past = pastNonRest(in: plan, before: today)
        past.dropLast(1).forEach { $0.isCompleted = true }

        let result = detector.detect(in: plan, today: today)
        #expect(result == nil)
    }

    @Test("Two trailing missed workouts triggers detection")
    func twoMissedTriggersDetection() {
        let plan = makePlan(startDate: date(2026, 4, 1))
        let today = date(2026, 5, 1)
        let past = pastNonRest(in: plan, before: today)
        guard past.count >= 2 else { return }
        past.dropLast(2).forEach { $0.isCompleted = true }

        let result = detector.detect(in: plan, today: today)
        #expect(result != nil)
        #expect(result?.count == 2)
    }

    @Test("All past workouts missed triggers detection with full count")
    func allMissedTriggersDetection() {
        let plan = makePlan(startDate: date(2026, 4, 1))
        let today = date(2026, 5, 1)
        let past = pastNonRest(in: plan, before: today)
        guard past.count >= 2 else { return }

        // Leave all as not completed (default)
        let result = detector.detect(in: plan, today: today)
        #expect(result != nil)
        #expect(result?.count == past.count)
    }

    // MARK: Streak reset

    @Test("Completed workout at the end of the gap resets trailing streak")
    func completedWorkoutResetsStreak() {
        let plan = makePlan(startDate: date(2026, 4, 1))
        let today = date(2026, 5, 1)
        let past = pastNonRest(in: plan, before: today)
        guard past.count >= 3 else { return }

        // Leave first N-1 missed, mark the last as completed → trailing streak = 0
        past.dropLast(1).forEach { $0.isCompleted = false }
        past.last!.isCompleted = true

        let result = detector.detect(in: plan, today: today)
        #expect(result == nil)
    }

    @Test("Completed workout in middle resets streak — only trailing misses count")
    func completedInMiddleResetsTrailingStreak() {
        let plan = makePlan(startDate: date(2026, 4, 1))
        let today = date(2026, 5, 1)
        let past = pastNonRest(in: plan, before: today)
        guard past.count >= 4 else { return }

        // Pattern: missed, missed, completed, missed → trailing streak = 1 → no trigger
        past[0].isCompleted = false
        past[1].isCompleted = false
        past[past.count - 2].isCompleted = true
        past[past.count - 1].isCompleted = false

        let result = detector.detect(in: plan, today: today)
        #expect(result == nil)
    }

    // MARK: Days to shift

    @Test("daysToShift equals days between first missed workout and today")
    func daysToShiftIsCorrect() {
        let startDate = date(2026, 4, 1)
        let today = date(2026, 5, 1)
        let plan = makePlan(startDate: startDate)
        // Leave all past workouts as missed
        let past = pastNonRest(in: plan, before: today)
        guard let first = past.first else { return }

        let result = detector.detect(in: plan, today: today)
        #expect(result != nil)

        let expected = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: first.scheduledDate),
            to: Calendar.current.startOfDay(for: today)
        ).day ?? 0
        #expect(result!.daysToShift == expected)
    }

    // MARK: Excluded types

    @Test("Rest workouts are excluded and do not count toward streak")
    func restWorkoutsExcluded() {
        let plan = makePlan(startDate: date(2026, 4, 1))
        let today = date(2026, 5, 1)
        // Mark all non-rest past workouts as completed except the last one
        let past = pastNonRest(in: plan, before: today)
        guard past.count >= 2 else { return }
        past.dropLast(1).forEach { $0.isCompleted = true }
        // Only 1 trailing miss — should not trigger
        let result = detector.detect(in: plan, today: today)
        #expect(result == nil)
    }
}
