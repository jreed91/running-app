import Foundation
import Testing
@testable import Stride

// MARK: - Re-filing re-paced sessions with the Workout app (P2.4)
//
// The post-run pace refresh rewrites every future session in place. The ones already
// filed with the Workout app are re-filed after it, and only those: re-filing goes
// through the single-workout sync, which edits what is there and never asks for
// WorkoutKit authorization after a run.

@MainActor
struct PlanLifecycleRefileTests {

    @Test("Only filed, unfinished sessions after today are re-filed, soonest first (P2.4)")
    func repacedSessionsOnTheWatch() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: today) ?? today
        }

        let plan = TrainingPlan(targetRace: .fiveK, goalTimeSeconds: 1_500, startDate: day(-7), endDate: day(21))
        let week = TrainingWeek(weekNumber: 1, startDate: day(-1), phase: .base, targetDistanceKm: 20)

        let later = ScheduledWorkout(scheduledDate: day(3), workoutType: .tempo)
        later.healthKitPlanID = "later"
        let tomorrow = ScheduledWorkout(scheduledDate: day(1), workoutType: .easy)
        tomorrow.healthKitPlanID = "tomorrow"
        // `refreshPaces` leaves today's session alone, so there is nothing to re-file.
        let todays = ScheduledWorkout(scheduledDate: today, workoutType: .easy)
        todays.healthKitPlanID = "today"
        let done = ScheduledWorkout(scheduledDate: day(2), workoutType: .interval)
        done.healthKitPlanID = "done"
        done.isCompleted = true
        // Never filed (outside the Workout app's window): a full sync adds it later.
        let notFiled = ScheduledWorkout(scheduledDate: day(4), workoutType: .longRun)

        week.workouts = [later, tomorrow, todays, done, notFiled]
        plan.weeks = [week]

        let refiled = PlanLifecycleService.repacedSessionsOnTheWatch(in: plan, now: now, calendar: calendar)

        #expect(refiled.map(\.id) == [tomorrow.id, later.id])
    }
}
