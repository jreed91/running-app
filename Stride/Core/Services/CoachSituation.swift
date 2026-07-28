import Foundation

// MARK: - CoachSituation

/// Where the runner stands right now, as one value.
///
/// The coaching strip used to be eleven independent rules that each decided for
/// themselves whether to fire, ordered by a hand-written priority list. That made the
/// list the design: the answer to "why am I seeing this card" was "because it happened
/// to be seventh", and nothing anywhere said what the runner's situation actually *was*.
///
/// This resolves that first. Everything downstream — which cards are even candidates,
/// whether one of them takes the whole strip, what the empty half of the screen says —
/// reads from this single value, so the selection is a function of state rather than of
/// eleven independent guards.
///
/// Pure, with an injectable `now` and `calendar`, like ``WidgetSnapshotBuilder`` and
/// ``ScheduledDayResolver``.
enum CoachSituation: Equatable, Sendable {

    /// Race day. Nothing else is worth saying.
    case raceDay
    /// A race inside the week — the taper, and how to eat through it.
    case raceWeek(daysOut: Int)
    /// Long enough since the last run that getting back out is the whole job.
    case returningFromLayoff(days: Int)
    /// A demanding run finished inside the recovery window.
    case recovering(minutesSinceFinish: Int)
    /// A run is scheduled and outstanding. The shape says what kind of advice it wants.
    case sessionAhead(SessionShape)
    /// The plan covers today and asks for nothing.
    case restDay
    /// The plan exists but has not begun.
    case beforePlanStart(daysUntilStart: Int)
    /// The plan is over — every session behind them, or the end date passed.
    case planFinished
    /// No active plan at all.
    case noPlan

    /// How the next session wants to be talked about. Coarser than `WorkoutType`
    /// deliberately: a 20 km long run and a 2-hour easy run take the same advice, and
    /// splitting tempo from interval would give two cards that say the same thing.
    enum SessionShape: Equatable, Sendable {
        /// Past the point where fuel has to be taken *during* the session.
        case enduring
        /// Hard enough that what was eaten beforehand decides how it goes.
        case quality
        /// Short and steady — nothing about it needs special handling.
        case steady
        /// A gym or cross-training day. Not a run, so the run-shaped advice stays quiet.
        case nonRun
    }

    // MARK: Classification

    /// Whether this situation owns the whole strip.
    ///
    /// Three of them do, and they are the three where a second card would be noise: on
    /// race morning, in race week, and after a fortnight off, there is exactly one thing
    /// worth saying and the runner should not have to pick it out of a list. Everything
    /// else competes on score.
    var isExclusive: Bool {
        switch self {
        case .raceDay, .raceWeek, .returningFromLayoff:
            return true
        case .recovering, .sessionAhead, .restDay, .beforePlanStart, .planFinished, .noPlan:
            return false
        }
    }

    /// Whether the plan has nothing outstanding to train toward.
    ///
    /// These are the states the dashboard's lower half used to go blank in. Each one gets
    /// its own designated card rather than sharing a single "nothing to do" fallback —
    /// "your plan starts Monday" and "you have no plan" are opposite problems, and a
    /// rest day is not a problem at all.
    var isEmpty: Bool {
        switch self {
        case .restDay, .beforePlanStart, .planFinished, .noPlan:
            return true
        case .raceDay, .raceWeek, .returningFromLayoff, .recovering, .sessionAhead:
            return false
        }
    }

    // MARK: - Resolution

    /// How long since the last run before coming back is the message.
    static let layoffDays = 6
    /// How long after a demanding run the recovery window stays open. Measured from the
    /// run's *finish*, so a two-hour long run does not expire before the runner is home.
    static let recoveryWindowSeconds: TimeInterval = 2 * 3_600
    /// Distance below which an easy run does not count as demanding on its own.
    static let demandingDistanceMeters = 8_000.0
    /// A race inside this many days is race week.
    static let raceWeekWindowDays = 7
    /// Distance at which a session needs carbohydrate taken during it.
    static let enduringDistanceMeters = 16_000.0
    /// Duration at which the same becomes true regardless of distance.
    static let enduringDurationSeconds: TimeInterval = 90 * 60

    /// Classifies the runner's situation.
    ///
    /// Order matters and is the design: race day beats everything, a lay-off beats the
    /// plan (there is no point prescribing Thursday's tempo to someone who has not run in
    /// a fortnight), and the recovery window beats the next session because it closes
    /// within the hour while the next session does not.
    ///
    /// - Parameters:
    ///   - nextSession: the plan's next outstanding session from today, or nil.
    ///   - recentRuns: recent runs in any order; sorted newest-first internally.
    ///   - dayState: what the plan says about *today*, from ``ScheduledDayResolver``.
    static func resolve(
        nextSession: ScheduledWorkout?,
        recentRuns: [RunWorkout],
        profile: UserProfile?,
        dayState: ScheduledDayResolver.DayState,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CoachSituation {
        let runs = recentRuns.sorted { $0.date > $1.date }

        if let race = raceProximity(profile: profile, now: now, calendar: calendar) {
            return race == 0 ? .raceDay : .raceWeek(daysOut: race)
        }

        if let days = daysSinceLastRun(runs: runs, now: now, calendar: calendar), days >= layoffDays {
            return .returningFromLayoff(days: days)
        }

        if let minutes = minutesSinceDemandingFinish(runs: runs, now: now) {
            return .recovering(minutesSinceFinish: minutes)
        }

        if let nextSession {
            return .sessionAhead(shape(of: nextSession))
        }

        // No outstanding session: the plan's own reading of today is the answer, and each
        // of its readings means something different (N23).
        switch dayState {
        case .rest, .scheduled:            return .restDay
        case .beforePlanStart(let days):   return .beforePlanStart(daysUntilStart: days)
        case .outsidePlan:                 return .planFinished
        case .noPlan:                      return .noPlan
        }
    }

    /// Days until the runner's goal race, when it is inside race week. Nil otherwise.
    static func raceProximity(
        profile: UserProfile?,
        now: Date,
        calendar: Calendar
    ) -> Int? {
        guard let profile, profile.goalRace.isGoalRace, let raceDate = profile.raceDate else { return nil }
        guard let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: raceDate)
        ).day, (0...raceWeekWindowDays).contains(days) else { return nil }
        return days
    }

    /// Whole days between the most recent run and today. Nil when nothing has been logged
    /// — a runner with no history is not returning from anything.
    static func daysSinceLastRun(
        runs: [RunWorkout],
        now: Date,
        calendar: Calendar
    ) -> Int? {
        guard let last = runs.max(by: { $0.date < $1.date }) else { return nil }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: last.date),
            to: calendar.startOfDay(for: now)
        ).day
    }

    /// Minutes since a demanding run finished, while that is still inside the window.
    ///
    /// "Demanding" is the bar for a refuelling prompt being worth making: far enough to
    /// have emptied something, or a session whose type says so regardless of distance.
    static func minutesSinceDemandingFinish(runs: [RunWorkout], now: Date) -> Int? {
        guard let run = runs.max(by: { $0.date < $1.date }) else { return nil }
        let elapsed = now.timeIntervalSince(run.date.addingTimeInterval(run.durationSeconds))
        guard elapsed >= 0, elapsed <= recoveryWindowSeconds else { return nil }

        let demanding = run.distanceMeters >= demandingDistanceMeters
            || run.workoutType.isQualitySession
            || run.workoutType == .longRun
        guard demanding else { return nil }

        return max(1, Int((elapsed / 60).rounded()))
    }

    /// How a scheduled session wants to be talked about.
    static func shape(of workout: ScheduledWorkout) -> SessionShape {
        guard workout.workoutType.isRunType else { return .nonRun }

        let distance = workout.targetDistanceMeters ?? 0
        let duration = NextUpBriefing.estimatedDurationSeconds(for: workout) ?? 0
        if distance >= enduringDistanceMeters || duration >= enduringDurationSeconds {
            return .enduring
        }
        return workout.workoutType.isQualitySession ? .quality : .steady
    }
}
