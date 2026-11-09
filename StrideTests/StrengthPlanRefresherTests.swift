import Foundation
import Testing
@testable import Stride

/// Covers `StrengthPlanRefresher`: changing strength equipment or focus in Settings
/// rewrites only the sessions still ahead, and keeps a pregnancy plan's adaptations.
@MainActor
struct StrengthPlanRefresherTests {

    private let calendar = Calendar.current
    private let now = Date()

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
    }

    private func strengthDay(_ offset: Int, done: Bool = false) -> ScheduledWorkout {
        let workout = ScheduledWorkout(scheduledDate: day(offset), workoutType: .strength)
        workout.strengthPlan = StrengthLibrary.plan(for: [.bodyweight], focus: .runningSpecific, phase: .build)
        workout.isCompleted = done
        return workout
    }

    @Test("Only unfinished strength sessions from today on are rewritten")
    func rewritesOnlyWhatIsAhead() {
        let plan = TrainingPlan(targetRace: .halfMarathon, goalTimeSeconds: 6_000, startDate: day(-14), endDate: day(60))
        let week = TrainingWeek(weekNumber: 3, startDate: day(-3), phase: .build, targetDistanceKm: 30)
        let past = strengthDay(-2)
        let finished = strengthDay(1, done: true)
        let today = strengthDay(0)
        let ahead = strengthDay(3)
        let run = ScheduledWorkout(scheduledDate: day(2), workoutType: .easy)
        week.workouts = [past, finished, today, ahead, run]
        plan.weeks = [week]
        let before = past.strengthPlan

        let changed = StrengthPlanRefresher.refresh(plan, equipment: [.barbell], focus: .generalStrength, now: now, calendar: calendar)

        let expected = StrengthLibrary.plan(for: [.barbell], focus: .generalStrength, phase: .build)
        #expect(changed == 2)
        #expect(today.strengthPlan == expected)
        #expect(ahead.strengthPlan == expected)
        #expect(past.strengthPlan == before)
        #expect(finished.strengthPlan == before)
        #expect(run.strengthPlan == nil)
        #expect(ahead.notes?.hasPrefix(StrengthFocus.generalStrength.displayName) == true)
    }

    @Test("Each week keeps its own phase")
    func followsEachWeeksPhase() {
        let plan = TrainingPlan(targetRace: .marathon, goalTimeSeconds: 14_000, startDate: day(-7), endDate: day(60))
        let build = TrainingWeek(weekNumber: 1, startDate: day(0), phase: .build, targetDistanceKm: 40)
        let taper = TrainingWeek(weekNumber: 2, startDate: day(7), phase: .taper, targetDistanceKm: 20)
        let buildDay = strengthDay(2)
        let taperDay = strengthDay(9)
        build.workouts = [buildDay]
        taper.workouts = [taperDay]
        plan.weeks = [build, taper]

        StrengthPlanRefresher.refresh(plan, equipment: [.dumbbells], focus: .runningSpecific, now: now, calendar: calendar)

        #expect(buildDay.strengthPlan == StrengthLibrary.plan(for: [.dumbbells], focus: .runningSpecific, phase: .build))
        #expect(taperDay.strengthPlan == StrengthLibrary.plan(for: [.dumbbells], focus: .runningSpecific, phase: .taper))
    }

    @Test("A pregnancy plan keeps its trimester adaptation and its own notes")
    func pregnancyKeepsItsAdaptation() {
        let dueDate = day(70) // 30 weeks along today: past the supine cut-off
        let plan = TrainingPlan(targetRace: .maintainFitness, goalTimeSeconds: 0, startDate: day(-7), endDate: dueDate)
        plan.planKind = .pregnancy
        plan.dueDate = dueDate
        let week = TrainingWeek(weekNumber: 1, startDate: day(0), phase: .base, targetDistanceKm: 10)
        let session = strengthDay(1)
        session.notes = "Pelvic floor first"
        week.workouts = [session]
        plan.weeks = [week]

        StrengthPlanRefresher.refresh(plan, equipment: [.dumbbells], focus: .generalStrength, now: now, calendar: calendar)

        let weeks = GestationalAge.on(day(0), dueDate: dueDate, calendar: calendar).weeks
        let expected = PregnancyStrengthAdapter.adapt(
            StrengthLibrary.plan(for: [.dumbbells], focus: .generalStrength, phase: .base),
            atGestationalWeek: weeks
        )
        #expect(session.strengthPlan == expected)
        #expect(session.notes == "Pelvic floor first")
    }

    @Test("Changing sessions a week re-places only the strength days still ahead")
    func reschedulesDaysAhead() {
        let profile = UserProfile(name: "Test", goalRace: .halfMarathon, goalFinishTime: 6_000, weeklyRunDays: 4, fitnessLevel: .intermediate)
        profile.selectedEquipment = [.dumbbells]
        profile.strengthFocus = .runningSpecific
        let plan = TrainingPlan(targetRace: .halfMarathon, goalTimeSeconds: 6_000, startDate: day(7), endDate: day(60))
        let week = TrainingWeek(weekNumber: 1, startDate: day(7), phase: .build, targetDistanceKm: 30)
        let tempo = ScheduledWorkout(scheduledDate: day(9), workoutType: .tempo)
        let long = ScheduledWorkout(scheduledDate: day(13), workoutType: .longRun)
        let oldStrength = strengthDay(7)
        week.workouts = [tempo, long, oldStrength]
        plan.weeks = [week]

        let removed = StrengthPlanRefresher.reschedule(
            plan, profile: profile,
            preferences: StrengthPreferences(daysPerWeek: 1, sessionMinutes: 25),
            now: now, calendar: calendar
        )

        let strength = (week.workouts ?? []).filter { $0.workoutType == .strength }
        #expect(removed.map(\.id) == [oldStrength.id])
        #expect(strength.count == 1)
        #expect((week.workouts ?? []).contains { $0.id == tempo.id })
        #expect(strength.first?.strengthPlan?.exercises.count == StrengthLibrary.minimumExercisesForLength)
    }
}
