import Foundation

// MARK: - ScheduledDayResolver

/// Resolves what a training plan has scheduled on a given calendar day, and whether
/// one of those sessions can still be started.
///
/// The dashboard used to answer both questions inline, and got both wrong:
///
/// - It resolved a day to **one** workout by first match over an unordered SwiftData
///   relationship, so a day holding a run *and* a gym session showed an arbitrary one
///   of the two and left the other unreachable (N12). Same-day pairs are ordinary now
///   that "pick up where I left off" shifts strength along with the runs.
/// - It offered the start button only on `isDateInToday`, so a session missed by a day
///   could not be started at all — stricter than `WorkoutSyncService`, which happily
///   links a run to yesterday's scheduled workout (N24).
enum ScheduledDayResolver {

    /// Every workout the plan schedules on `date`, including rest days.
    ///
    /// Ordered runs first, then strength, cross-training, and rest, with earlier
    /// scheduled times ahead of later ones. Relationship order is undefined, so
    /// without this the render order could change between passes.
    static func workouts(
        on date: Date,
        in plan: TrainingPlan?,
        calendar: Calendar = .current
    ) -> [ScheduledWorkout] {
        guard let plan else { return [] }
        let matches = (plan.weeks ?? []).flatMap { week in
            (week.workouts ?? []).filter { calendar.isDate($0.scheduledDate, inSameDayAs: date) }
        }
        return matches.sorted(by: isOrderedBefore)
    }

    /// The sessions worth showing on a day card: everything except an explicit rest day.
    ///
    /// Empty means "nothing to do here", which the caller must not confuse with
    /// "the plan says rest" — the two read the same to a user but mean different
    /// things (N23).
    static func sessions(
        on date: Date,
        in plan: TrainingPlan?,
        calendar: Calendar = .current
    ) -> [ScheduledWorkout] {
        workouts(on: date, in: plan, calendar: calendar).filter { $0.workoutType != .rest }
    }

    /// What a day means when it holds no session to start.
    ///
    /// The dashboard rendered the same "Rest day · Recovery is part of training" card
    /// for all three of these (N23), so scrolling to next month — or opening the app
    /// before ever making a plan — told the runner they were resting according to a
    /// plan that says nothing about that day.
    enum DayState: Equatable {
        /// The plan schedules work: one or more non-rest sessions.
        case scheduled
        /// The plan covers this day and asks for nothing — a genuine rest day.
        case rest
        /// There is an active plan, but this date falls outside its range.
        case outsidePlan
        /// No active plan at all.
        case noPlan
    }

    /// Classifies `date` against the plan. Pure, so the three empty cases can be tested
    /// without a view.
    static func dayState(
        on date: Date,
        in plan: TrainingPlan?,
        calendar: Calendar = .current
    ) -> DayState {
        guard let plan else { return .noPlan }
        guard sessions(on: date, in: plan, calendar: calendar).isEmpty else { return .scheduled }

        let day = calendar.startOfDay(for: date)
        let start = calendar.startOfDay(for: plan.startDate)
        let end = calendar.startOfDay(for: plan.endDate)
        // A plan whose end precedes its start is malformed rather than empty; it covers
        // no days, so every date is outside it.
        guard start <= end else { return .outsidePlan }
        return (start...end).contains(day) ? .rest : .outsidePlan
    }

    /// Whether an uncompleted session scheduled on `date` can be started now.
    ///
    /// Today, plus one day late — the same tolerance `WorkoutSyncService` applies when
    /// it links an imported run to a scheduled day. Future days stay unstartable so
    /// the plan isn't run out of order.
    static func canStart(
        workoutScheduledOn date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let daysLate = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day else { return false }
        return (0...maximumDaysLateToStart).contains(daysLate)
    }

    /// How many days after the scheduled day a session can still be started.
    static let maximumDaysLateToStart = 1

    /// Sort order used for a day's sessions: run work first, then strength,
    /// cross-training, and rest; ties broken by scheduled time, then by ID so the
    /// order is fully determined.
    private static func isOrderedBefore(_ lhs: ScheduledWorkout, _ rhs: ScheduledWorkout) -> Bool {
        let lhsRank = kindRank(lhs.workoutType.sessionKind)
        let rhsRank = kindRank(rhs.workoutType.sessionKind)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.scheduledDate != rhs.scheduledDate { return lhs.scheduledDate < rhs.scheduledDate }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func kindRank(_ kind: WorkoutType.SessionKind) -> Int {
        switch kind {
        case .run:           return 0
        case .strength:      return 1
        case .crossTraining: return 2
        case .rest:          return 3
        }
    }
}
