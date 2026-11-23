import Foundation
import SwiftData

// MARK: - TrainingBreakApplier

/// Writes a ``TrainingBreakPlanner/Proposal`` into the plan, and takes it back out.
///
/// Like ``PlanChangeApplier``, every run it writes is built by
/// ``TrainingPlanService/adaptWorkout(scheduled:history:profile:unitPreference:)`` from a
/// stub carrying only the day, the type and the distance, so the paces and the shape of a
/// shortened tempo or long run are the plan's own. A rest day is written the way the plan
/// keeps one: no targets, no reps, no structure.
///
/// The store is all this touches. `PlanLifecycleService` re-files the changed sessions
/// with the Watch and re-schedules the morning reminders after it.
@MainActor
enum TrainingBreakApplier {

    enum ApplyError: Error, Equatable {
        /// The plan already has a break that isn't finished. Undo it first.
        case alreadyOnBreak
        /// A session the proposal named is gone, done, or no longer what it was.
        case planChanged
    }

    /// Writes `proposal` into `plan`, saves, and keeps the record.
    ///
    /// - Returns: the saved break and the sessions that changed.
    /// - Throws: before writing anything, when the plan has a live break already or no
    ///   longer matches the plan the proposal was made from.
    static func start(
        _ proposal: TrainingBreakPlanner.Proposal,
        in plan: TrainingPlan,
        context: ModelContext,
        history: [RunWorkout],
        profile: UserProfile,
        unitPreference: UnitPreference,
        service: TrainingPlanService = TrainingPlanService(),
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) throws -> (TrainingBreak, [ScheduledWorkout]) {
        guard TrainingBreakStore.current(forPlan: plan.id, now: now, in: defaults) == nil else {
            throw ApplyError.alreadyOnBreak
        }
        let changes = try write(
            proposal.edits,
            reason: proposal.request.reason,
            in: plan,
            history: history,
            profile: profile,
            unitPreference: unitPreference,
            service: service
        )
        context.saveOrLog("the training break")

        let record = TrainingBreak(
            planID: plan.id,
            reason: proposal.request.reason,
            mode: proposal.request.mode,
            startDate: proposal.startDate,
            endDate: proposal.endDate,
            rampEndDate: proposal.rampEndDate,
            createdAt: now,
            changes: changes.map(\.record)
        )
        TrainingBreakStore.save(record, now: now, in: defaults)
        return (record, changes.map(\.session))
    }

    /// Puts back every session the break changed that is still ahead and still the way
    /// the break left it, and forgets the break.
    ///
    /// - Returns: the sessions put back.
    @discardableResult
    static func undo(
        _ trainingBreak: TrainingBreak,
        in plan: TrainingPlan,
        context: ModelContext,
        now: Date = Date(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> [ScheduledWorkout] {
        let today = calendar.startOfDay(for: now)
        let restored = restore(trainingBreak.changes, in: plan, onOrAfter: today, calendar: calendar)
        TrainingBreakStore.remove(id: trainingBreak.id, in: defaults)
        context.saveOrLog("undoing the training break")
        return restored.sessions
    }

    /// "I'm back": puts the rest of the break back as planned, then eases the runner in
    /// from today for the days they actually had off.
    ///
    /// - Returns: every session that changed, put back or eased.
    @discardableResult
    static func endEarly(
        _ trainingBreak: TrainingBreak,
        in plan: TrainingPlan,
        context: ModelContext,
        history: [RunWorkout],
        profile: UserProfile,
        unitPreference: UnitPreference,
        service: TrainingPlanService = TrainingPlanService(),
        now: Date = Date(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> [ScheduledWorkout] {
        let today = calendar.startOfDay(for: now)
        let restored = restore(trainingBreak.changes, in: plan, onOrAfter: today, calendar: calendar)

        var record = trainingBreak
        record.endDate = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        record.rampEndDate = nil
        // The days already behind keep their record; the ones put back don't need one.
        record.changes = trainingBreak.changes.filter { !restored.ids.contains($0.sessionID) }

        var eased: [ScheduledWorkout] = []
        if let ramp = TrainingBreakPlanner.rampForEarlyReturn(
            reason: trainingBreak.reason,
            mode: trainingBreak.mode,
            breakStart: trainingBreak.startDate,
            in: PlanChangeApplier.snapshot(of: plan),
            now: now,
            calendar: calendar
        ), let changes = try? write(
            ramp.edits,
            reason: trainingBreak.reason,
            in: plan,
            history: history,
            profile: profile,
            unitPreference: unitPreference,
            service: service
        ) {
            record.rampEndDate = ramp.lastDay
            record.changes += changes.map(\.record)
            eased = changes.map(\.session)
        }

        if record.phase(on: now, calendar: calendar) == .finished {
            TrainingBreakStore.remove(id: record.id, in: defaults)
        } else {
            TrainingBreakStore.save(record, now: now, in: defaults)
        }
        context.saveOrLog("ending the training break early")

        let easedIDs = Set(eased.map(\.id))
        return eased + restored.sessions.filter { !easedIDs.contains($0.id) }
    }

    // MARK: - Writing

    private struct Written {
        let session: ScheduledWorkout
        let record: TrainingBreak.ChangedSession
    }

    /// Checks every edit against the plan first, then writes them all, so a plan that
    /// moved since the proposal is left untouched.
    private static func write(
        _ edits: [TrainingBreakPlanner.Edit],
        reason: TrainingBreak.Reason,
        in plan: TrainingPlan,
        history: [RunWorkout],
        profile: UserProfile,
        unitPreference: UnitPreference,
        service: TrainingPlanService
    ) throws -> [Written] {
        let byID = Dictionary(
            (plan.weeks ?? []).flatMap { $0.workouts ?? [] }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let targets: [(TrainingBreakPlanner.Edit, ScheduledWorkout)] = try edits.map { edit in
            guard let session = byID[edit.sessionID],
                  !session.isCompleted,
                  session.workoutType == edit.fromType else { throw ApplyError.planChanged }
            return (edit, session)
        }

        return targets.map { edit, session in
            let original = session.breakContent
            let note = Self.note(for: edit, reason: reason)
            switch edit.outcome {
            case .rest:
                session.workoutType = .rest
                session.targetDistanceMeters = nil
                session.targetPaceLowerBound = nil
                session.targetPaceUpperBound = nil
                session.intervals = []
                session.workoutStructure = nil
                session.strengthData = nil
                // `healthKitPlanID` stays: the Watch sync uses it to take the old workout off.
                session.notes = note
            case let .run(type, distance):
                let stub = ScheduledWorkout(scheduledDate: session.scheduledDate, workoutType: type, targetDistanceMeters: distance)
                if type == edit.fromType {
                    // Same kind of run, shorter: keep the session's own reps.
                    stub.intervals = session.intervals
                }
                let built = service.adaptWorkout(scheduled: stub, history: history, profile: profile, unitPreference: unitPreference)
                session.applyAdaptation(from: built)
                session.notes = [note, built.notes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            }
            return Written(
                session: session,
                record: .init(
                    sessionID: session.id,
                    original: original,
                    appliedTypeRaw: session.workoutTypeRaw,
                    appliedDistanceMeters: session.targetDistanceMeters
                )
            )
        }
    }

    /// Puts back the changes dated `onOrAfter` or later whose session still looks the way
    /// the break left it.
    private static func restore(
        _ changes: [TrainingBreak.ChangedSession],
        in plan: TrainingPlan,
        onOrAfter day: Date,
        calendar: Calendar
    ) -> (sessions: [ScheduledWorkout], ids: Set<UUID>) {
        let byID = Dictionary(
            (plan.weeks ?? []).flatMap { $0.workouts ?? [] }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var restored: [ScheduledWorkout] = []
        for change in changes {
            guard let session = byID[change.sessionID],
                  !session.isCompleted,
                  calendar.startOfDay(for: session.scheduledDate) >= day,
                  session.workoutTypeRaw == change.appliedTypeRaw,
                  session.targetDistanceMeters == change.appliedDistanceMeters else { continue }
            session.restore(change.original)
            restored.append(session)
        }
        return (restored, Set(restored.map(\.id)))
    }

    // MARK: - Notes

    static func note(for edit: TrainingBreakPlanner.Edit, reason: TrainingBreak.Reason) -> String {
        switch (edit.stage, edit.outcome, reason) {
        case (.onBreak, .rest, .ill):
            return String(localized: "Rest day while you're unwell. Rest is the training today.", comment: "Note on a session a training break turned into a rest day, runner is ill")
        case (.onBreak, .rest, .injured):
            return String(localized: "Rest day while you're injured.", comment: "Note on a session a training break turned into a rest day, runner is injured")
        case (.onBreak, .rest, .travelling):
            return String(localized: "Rest day while you're away.", comment: "Note on a session a training break turned into a rest day, runner is travelling")
        case (.onBreak, .run, .ill):
            return String(localized: "Short and easy while you're unwell. Stop if you feel worse.", comment: "Note on a run a training break made short and easy, runner is ill")
        case (.onBreak, .run, .injured):
            return String(localized: "Short and easy while you're injured. Stop if it hurts.", comment: "Note on a run a training break made short and easy, runner is injured")
        case (.onBreak, .run, .travelling):
            return String(localized: "Short and easy while you're away.", comment: "Note on a run a training break made short and easy, runner is travelling")
        case (.easingBack, _, _):
            return String(localized: "Easing back in after your break, so it's shorter than planned.", comment: "Note on a run shortened while the runner eases back in after a training break")
        }
    }
}

// MARK: - ScheduledWorkout content

extension ScheduledWorkout {

    /// What the session prescribes, as a training break keeps it for undo.
    var breakContent: TrainingBreak.SessionContent {
        TrainingBreak.SessionContent(
            workoutTypeRaw: workoutTypeRaw,
            targetDistanceMeters: targetDistanceMeters,
            targetPaceLowerBound: targetPaceLowerBound,
            targetPaceUpperBound: targetPaceUpperBound,
            notes: notes,
            intervalsData: intervalsData,
            structureData: structureData,
            strengthData: strengthData
        )
    }

    /// Puts back what a training break kept. `healthKitPlanID` is left as it is: the
    /// caller re-files the session, and the sync removes the break's version by it.
    func restore(_ content: TrainingBreak.SessionContent) {
        workoutTypeRaw = content.workoutTypeRaw
        targetDistanceMeters = content.targetDistanceMeters
        targetPaceLowerBound = content.targetPaceLowerBound
        targetPaceUpperBound = content.targetPaceUpperBound
        notes = content.notes
        intervalsData = content.intervalsData
        structureData = content.structureData
        strengthData = content.strengthData
    }
}
