import Foundation
import SwiftData

// MARK: - PlanChangeApplier

/// Writes a ``PlanChangePlanner/Change`` into the plan the runner confirmed it for.
///
/// The planner decides *what* changes from a plain copy of the plan; this builds the
/// session and saves it. Every run it writes is built by
/// ``TrainingPlanService/adaptWorkout(scheduled:history:profile:unitPreference:)`` from a
/// stub carrying only the day, the type and the distance, so the paces, reps and
/// warm-up are today's, from the same rules the post-run refresh uses. Nothing the
/// model wrote reaches the session except that shape.
///
/// What this does not do is talk to the world outside the store: the caller re-files the
/// changed session with the Watch (`HealthKitRepository.syncWorkoutPlan(for:)`, which
/// also takes a run turned into a rest day off it), refreshes the widgets and
/// re-schedules the morning reminder, as the coach's "Update next session" does.
@MainActor
enum PlanChangeApplier {

    enum ApplyError: Error, Equatable {
        /// The plan moved between the proposal and the tap: the session is gone or done,
        /// the day has a run now, or no week of the plan holds the day.
        case planChanged
    }

    /// The plan as the planner reads it.
    static func snapshot(of plan: TrainingPlan) -> PlanChangePlanner.Plan {
        PlanChangePlanner.Plan(
            sessions: (plan.weeks ?? []).flatMap { $0.workouts ?? [] }.map {
                PlanChangePlanner.Session(
                    id: $0.id,
                    date: $0.scheduledDate,
                    type: $0.workoutType,
                    isCompleted: $0.isCompleted,
                    targetDistanceMeters: $0.targetDistanceMeters
                )
            },
            startDate: plan.startDate,
            endDate: plan.endDate,
            raceDate: plan.raceDate,
            prescribesByTime: plan.prescribesByTime,
            breakDays: TrainingBreakStore.current(forPlan: plan.id).map { $0.startDate...($0.rampEndDate ?? $0.endDate) }
        )
    }

    /// Applies `change` to `plan` and saves it.
    ///
    /// - Returns: the session that changed: the new run, the run that changed type, or
    ///   the run that is now a rest day. The caller syncs it with the Watch.
    /// - Throws: ``ApplyError/planChanged`` when the plan no longer matches the one the
    ///   change was planned against. Nothing is written then.
    @discardableResult
    static func apply(
        _ change: PlanChangePlanner.Change,
        to plan: TrainingPlan,
        context: ModelContext,
        history: [RunWorkout],
        profile: UserProfile,
        unitPreference: UnitPreference,
        service: TrainingPlanService = TrainingPlanService(),
        calendar: Calendar = .current
    ) throws -> ScheduledWorkout {
        let all = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }

        func build(_ type: WorkoutType, on date: Date, distance: Double?) -> ScheduledWorkout {
            // A plain stub: no week, never inserted. `adaptWorkout` returns a fresh
            // instance built from it.
            let stub = ScheduledWorkout(scheduledDate: date, workoutType: type, targetDistanceMeters: distance)
            return service.adaptWorkout(scheduled: stub, history: history, profile: profile, unitPreference: unitPreference)
        }

        let changed: ScheduledWorkout
        switch change {
        case let .add(date, type, distance, replacingRestID):
            let sameDay = all.filter { calendar.isDate($0.scheduledDate, inSameDayAs: date) }
            guard !sameDay.contains(where: { $0.workoutType.isRunType }) else { throw ApplyError.planChanged }
            let built = build(type, on: date, distance: distance)

            if let restID = replacingRestID, let rest = sameDay.first(where: { $0.id == restID && $0.workoutType == .rest }) {
                rest.applyAdaptation(from: built)
                changed = rest
            } else {
                guard let week = (plan.weeks ?? []).first(where: { week in
                    let day = calendar.startOfDay(for: date)
                    return calendar.startOfDay(for: week.startDate) <= day && calendar.startOfDay(for: week.endDate) >= day
                }) else { throw ApplyError.planChanged }
                built.notes = addedNote(built.notes)
                context.insert(built)
                built.week = week
                // The refresh after the next run leaves it alone for a week, as it does
                // every session the runner changed through the coach.
                AdaptedSessions.record(built.id)
                changed = built
            }

        case let .changeType(sessionID, _, from, to, distance):
            guard let session = all.first(where: { $0.id == sessionID }),
                  !session.isCompleted,
                  session.workoutType == from else { throw ApplyError.planChanged }
            let built = build(to, on: session.scheduledDate, distance: distance)
            session.applyAdaptation(from: built)
            changed = session

        case let .makeRest(sessionID, _, type):
            guard let session = all.first(where: { $0.id == sessionID }),
                  !session.isCompleted,
                  session.workoutType == type else { throw ApplyError.planChanged }
            makeRest(session)
            changed = session
        }

        context.saveOrLog("the coach's plan change")
        return changed
    }

    /// Turns a run into a stored rest day, the way the plan already keeps one: no
    /// targets, no reps, no structure. The row stays, so the day keeps its place in the
    /// week and the Watch sync finds the workout it has to take off.
    static func makeRest(_ session: ScheduledWorkout) {
        session.workoutType = .rest
        session.targetDistanceMeters = nil
        session.targetPaceLowerBound = nil
        session.targetPaceUpperBound = nil
        session.intervals = []
        session.workoutStructure = nil
        session.notes = String(
            localized: "Rest day. You asked the coach to take this run off your plan.",
            comment: "Note on a planned run the runner turned into a rest day through the coach chat"
        )
        AdaptedSessions.record(session.id)
    }

    private static func addedNote(_ note: String?) -> String {
        let added = String(
            localized: "Added at your request through the coach.",
            comment: "Note on a run the runner added to their plan through the coach chat"
        )
        guard let note, !note.isEmpty else { return added }
        return "\(note) \(added)"
    }
}
