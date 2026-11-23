import Foundation
import SwiftData
import Testing
@testable import Stride

/// Writing a training break into the stored plan, undoing it, and "I'm back"
/// (`TrainingBreakApplier`).
@MainActor
struct TrainingBreakApplierTests {

    private let calendar = Calendar.current

    private let monday = Calendar.current.date(
        from: DateComponents(year: 2027, month: 3, day: 15, hour: 9)
    ) ?? .now

    private func day(_ offset: Int) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: monday) ?? monday)
    }

    private func morning(_ offset: Int) -> Date {
        calendar.date(byAdding: .hour, value: 9, to: day(offset)) ?? day(offset)
    }

    private var profile: UserProfile {
        UserProfile(
            name: "Runner",
            goalRace: .tenK,
            goalFinishTime: 3_000,
            weeklyRunDays: 3,
            fitnessLevel: .intermediate,
            currentEstimated5KTimeSeconds: 1_500
        )
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "TrainingBreakApplierTests-\(UUID())"))
    }

    /// Two weeks from this Monday: Tue tempo 8 km (paced, with a note), Thu easy 6 km,
    /// Sat long run 16 km.
    private func makeStoredPlan(in context: ModelContext) throws -> (TrainingPlan, tempo: ScheduledWorkout) {
        let plan = TrainingPlan(targetRace: .tenK, goalTimeSeconds: 3_000, startDate: day(-7), endDate: day(20))
        plan.isActive = true
        context.insert(plan)
        var tempo: ScheduledWorkout?
        for index in 0..<4 {
            let week = TrainingWeek(weekNumber: index + 1, startDate: day(-7 + index * 7), phase: .base, targetDistanceKm: 30)
            context.insert(week)
            week.plan = plan
            guard index >= 1 else { continue }
            let base = (index - 1) * 7
            let sessions = [
                ScheduledWorkout(scheduledDate: day(base + 1), workoutType: .tempo, targetDistanceMeters: 8_000,
                                 targetPaceLowerBound: 270, targetPaceUpperBound: 280, notes: "Tempo, controlled."),
                ScheduledWorkout(scheduledDate: day(base + 3), workoutType: .easy, targetDistanceMeters: 6_000),
                ScheduledWorkout(scheduledDate: day(base + 5), workoutType: .longRun, targetDistanceMeters: 16_000),
            ]
            for session in sessions {
                context.insert(session)
                session.week = week
            }
            if index == 1 { tempo = sessions[0] }
        }
        try context.save()
        return (plan, try #require(tempo))
    }

    private func proposal(_ mode: TrainingBreak.Mode, days: Int, for plan: TrainingPlan) throws -> TrainingBreakPlanner.Proposal {
        try TrainingBreakPlanner.propose(
            TrainingBreakRequest(reason: .ill, mode: mode, startDate: day(0), days: days),
            in: PlanChangeApplier.snapshot(of: plan),
            now: monday,
            calendar: calendar
        ).get()
    }

    @Test("A pause turns the runs into rest days, and undo puts them back exactly")
    func pauseAndUndo() throws {
        let context = TestStore.makeContext()
        let store = try defaults()
        let (plan, tempo) = try makeStoredPlan(in: context)

        let (record, changed) = try TrainingBreakApplier.start(
            try proposal(.pause, days: 5, for: plan),
            in: plan, context: context, history: [], profile: profile, unitPreference: .metric,
            now: monday, defaults: store
        )
        #expect(tempo.workoutType == .rest)
        #expect(tempo.targetPaceLowerBound == nil)
        #expect(changed.contains { $0.id == tempo.id })
        #expect(TrainingBreakStore.current(forPlan: plan.id, now: monday, in: store) == record)

        TrainingBreakApplier.undo(record, in: plan, context: context, now: monday, calendar: calendar, defaults: store)
        #expect(tempo.workoutType == .tempo)
        #expect(tempo.targetDistanceMeters == 8_000)
        #expect(tempo.targetPaceLowerBound == 270)
        #expect(tempo.notes == "Tempo, controlled.")
        #expect(TrainingBreakStore.current(forPlan: plan.id, now: monday, in: store) == nil)
    }

    @Test("Ease off rebuilds a run as a shorter easy run with today's paces")
    func easeOff() throws {
        let context = TestStore.makeContext()
        let (plan, tempo) = try makeStoredPlan(in: context)
        _ = try TrainingBreakApplier.start(
            try proposal(.easeOff, days: 3, for: plan),
            in: plan, context: context, history: [], profile: profile, unitPreference: .metric,
            now: monday, defaults: try defaults()
        )
        #expect(tempo.workoutType == .easy)
        #expect(tempo.targetDistanceMeters == 4_000)
        #expect(tempo.targetPaceLowerBound != nil)
        #expect(tempo.notes?.hasPrefix("Short and easy") == true)
    }

    @Test("Undo leaves a session the runner changed again since")
    func undoKeepsLaterEdits() throws {
        let context = TestStore.makeContext()
        let store = try defaults()
        let (plan, tempo) = try makeStoredPlan(in: context)
        let (record, _) = try TrainingBreakApplier.start(
            try proposal(.easeOff, days: 3, for: plan),
            in: plan, context: context, history: [], profile: profile, unitPreference: .metric,
            now: monday, defaults: store
        )
        tempo.targetDistanceMeters = 5_000
        TrainingBreakApplier.undo(record, in: plan, context: context, now: monday, calendar: calendar, defaults: store)
        #expect(tempo.workoutType == .easy)
        #expect(tempo.targetDistanceMeters == 5_000)
    }

    @Test("A plan that moved since the proposal throws and writes nothing; a second break is refused")
    func refusals() throws {
        let context = TestStore.makeContext()
        let store = try defaults()
        let (plan, tempo) = try makeStoredPlan(in: context)
        let stale = try proposal(.pause, days: 5, for: plan)
        tempo.isCompleted = true
        #expect(throws: TrainingBreakApplier.ApplyError.planChanged) {
            try TrainingBreakApplier.start(stale, in: plan, context: context, history: [], profile: profile,
                                           unitPreference: .metric, now: monday, defaults: store)
        }
        #expect(tempo.workoutType == .tempo)

        tempo.isCompleted = false
        _ = try TrainingBreakApplier.start(stale, in: plan, context: context, history: [], profile: profile,
                                           unitPreference: .metric, now: monday, defaults: store)
        #expect(throws: TrainingBreakApplier.ApplyError.alreadyOnBreak) {
            try TrainingBreakApplier.start(stale, in: plan, context: context, history: [], profile: profile,
                                           unitPreference: .metric, now: monday, defaults: store)
        }
    }

    @Test("Back early: the rest of the break is put back and the runner eases in from today")
    func endEarly() throws {
        let context = TestStore.makeContext()
        let store = try defaults()
        let (plan, _) = try makeStoredPlan(in: context)
        // Ill for ten days, Mon to the next Wed; back on Friday (day 4) after four days off.
        let (record, _) = try TrainingBreakApplier.start(
            try proposal(.pause, days: 10, for: plan),
            in: plan, context: context, history: [], profile: profile, unitPreference: .metric,
            now: monday, defaults: store
        )
        TrainingBreakApplier.endEarly(
            record, in: plan, context: context, history: [], profile: profile, unitPreference: .metric,
            now: morning(4), calendar: calendar, defaults: store
        )

        let all = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }
        let saturday = try #require(all.first { calendar.isDate($0.scheduledDate, inSameDayAs: day(5)) })
        let nextTuesday = try #require(all.first { calendar.isDate($0.scheduledDate, inSameDayAs: day(8)) })
        let nextThursday = try #require(all.first { calendar.isDate($0.scheduledDate, inSameDayAs: day(10)) })
        let tuesday = try #require(all.first { calendar.isDate($0.scheduledDate, inSameDayAs: day(1)) })

        #expect(tuesday.workoutType == .rest, "Days already behind stay as the break left them")
        #expect(saturday.workoutType == .longRun)
        #expect(saturday.targetDistanceMeters == 11_200, "A week's ramp: 70% in the first half")
        #expect(nextTuesday.workoutType == .tempo, "Quality returns in the second half, shorter")
        #expect(nextTuesday.targetDistanceMeters == 6_800)
        #expect(nextThursday.targetDistanceMeters == 5_100, "85% in the second half")

        let updated = try #require(TrainingBreakStore.current(forPlan: plan.id, now: morning(4), in: store))
        #expect(updated.endDate == day(3))
        #expect(updated.rampEndDate == day(10))
        #expect(updated.phase(on: morning(4), calendar: calendar) == .easingBack)
    }
}
