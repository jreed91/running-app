import Foundation

// MARK: - MissedWorkoutShift

/// Decides how far "pick up where I left off" is allowed to move a plan forward.
///
/// The shift itself is deliberately uniform: every remaining session moves by the
/// same number of days so the week keeps the spacing it was generated with. That is
/// what makes the recovery safe — it never drops a run onto a gym day and never
/// reorders quality work (N6).
///
/// A fixed race date is the one thing a uniform shift cannot simply ignore. Race
/// workouts are already held still, but nothing stopped the *rest* of the block from
/// sliding onto or past race day, which is how a runner four days behind ended up
/// with a tempo session scheduled the morning of their half marathon and a long run
/// the day after it. The requested shift is therefore clamped to the headroom that
/// actually exists between the last movable session and the day before the race, and
/// the caller is told what it got so it can say so rather than silently doing less
/// than the button promised.
///
/// Pure by design: `AppContainer` owned this date math (D2), which is why N6 had no
/// natural test home.
enum MissedWorkoutShift {

    // MARK: Outcome

    /// What a requested shift resolves to once the race date is taken into account.
    struct Outcome: Equatable {
        /// The shift the caller asked for, floored at zero.
        let requestedDays: Int
        /// The shift that may actually be applied.
        let appliedDays: Int

        /// Whether the race date is what held this shift back.
        ///
        /// "Nothing moved" has two causes that are indistinguishable in the numbers: the
        /// race left no headroom, or there was nothing to move in the first place. Only
        /// the first is the race's doing, and only the first is worth telling the runner
        /// about — `DashboardView.pickUpNotice` reads these flags to decide whether to
        /// blame race day, and without this it blamed race day for an empty plan.
        let isRaceLimited: Bool

        /// Nothing moves — either nothing was asked for, or the race leaves no room.
        var isNoOp: Bool { appliedDays <= 0 }

        /// The race date forced a smaller shift than the one requested.
        var wasClampedByRace: Bool { isRaceLimited && appliedDays < requestedDays }

        /// The race date left no room to move at all, and something was asked for.
        var wasBlockedByRace: Bool { isRaceLimited && requestedDays > 0 && appliedDays <= 0 }
    }

    // MARK: Resolution

    /// Resolves a requested shift against the plan's race date.
    ///
    /// - Parameters:
    ///   - requestedDays: How far behind the plan is, from `MissedWorkoutInfo.daysToShift`.
    ///   - lastMovableDate: The latest `scheduledDate` among the sessions that would
    ///     move. `nil` when there is nothing to move.
    ///   - raceDate: The plan's fixed race date, or `nil` for an open-ended plan.
    /// - Returns: The requested and applicable shifts. An open-ended plan applies the
    ///   request unchanged; a plan with nothing left to move resolves to a no-op, and
    ///   says so without implicating the race.
    static func resolve(
        requestedDays: Int,
        lastMovableDate: Date?,
        raceDate: Date?,
        calendar: Calendar = .current
    ) -> Outcome {
        let requested = max(0, requestedDays)
        guard requested > 0, let lastMovableDate else {
            return Outcome(requestedDays: requested, appliedDays: 0, isRaceLimited: false)
        }
        guard let raceDate else {
            return Outcome(requestedDays: requested, appliedDays: requested, isRaceLimited: false)
        }

        return Outcome(
            requestedDays: requested,
            appliedDays: min(requested, headroom(from: lastMovableDate, to: raceDate, calendar: calendar)),
            isRaceLimited: true
        )
    }

    /// Days the last movable session can travel and still land strictly before the race.
    ///
    /// Measured start-of-day to start-of-day so a 19:00 long run and an 06:00 race
    /// gun time are one day apart rather than a fraction of one, and floored at zero
    /// for a plan whose sessions already sit on or past race day.
    private static func headroom(
        from lastMovableDate: Date,
        to raceDate: Date,
        calendar: Calendar
    ) -> Int {
        let lastDay = calendar.startOfDay(for: lastMovableDate)
        let raceDay = calendar.startOfDay(for: raceDate)
        let daysUntilRace = calendar.dateComponents([.day], from: lastDay, to: raceDay).day ?? 0
        // The session may land at most on the day before the race, hence the -1.
        return max(0, daysUntilRace - 1)
    }
}
