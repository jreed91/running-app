import Foundation

// MARK: - TrainingNudgeKind

/// The notifications this policy decides about, as values — the request identifier, the
/// delivery-log key and the tap payload are all built from the raw value, so there is one
/// spelling of each rather than three string literals that can drift.
enum TrainingNudgeKind: String, Sendable, CaseIterable {
    /// "You haven't run today and the streak ends at midnight."
    case streak
    /// "The plan has run away from you — shift it forward."
    case missedWorkouts
    /// Sunday evening's read of the week just finished.
    case weeklyRecap
}

// MARK: - StreakNudge

/// A run streak that today's midnight will end unless the runner goes out.
struct StreakNudge: Equatable, Sendable {
    /// Length of the streak still standing, in days.
    let days: Int
}

// MARK: - WeeklyRecap

/// What the week just finished came to.
struct WeeklyRecap: Equatable, Sendable {
    /// Monday of the week being recapped.
    let weekStart: Date
    let runCount: Int
    let totalMeters: Double
    let longestRunMeters: Double
    /// The runner's weekly distance goal. Zero when they have never set one, in which
    /// case the recap is a readout with nothing to compare against.
    let goalMeters: Double

    var hasGoal: Bool { goalMeters > 0 }
    var isGoalMet: Bool { hasGoal && totalMeters >= goalMeters }
    var remainingMeters: Double { max(goalMeters - totalMeters, 0) }
}

// MARK: - TrainingNudge

/// The one thing worth saying in the evening slot.
///
/// An enum rather than three independent schedules because the slot holds one push: a
/// runner who is both mid-streak and behind their plan does not need two banners at 18:00
/// about the same evening. The Sunday recap keeps a slot of its own — it is a readout, not
/// a prod, and it is the one of the three that should never be crowded out.
enum TrainingNudge: Equatable, Sendable {
    case streak(StreakNudge)
    case missedWorkouts(MissedWorkoutInfo)

    var kind: TrainingNudgeKind {
        switch self {
        case .streak:         return .streak
        case .missedWorkouts: return .missedWorkouts
        }
    }
}

// MARK: - TrainingNudgeDelivery

/// When a nudge should reach the runner. Same three cases as
/// `NotificationService.HeatAdvisoryDelivery`, and for the same reason: the app has no
/// background wake of its own, so "the slot has already passed" is a case that has to be
/// decided rather than assumed away.
enum TrainingNudgeDelivery: Equatable, Sendable {
    /// The slot is still ahead — schedule it.
    case scheduled(Date)
    /// Past the slot but still inside the window where the message can be acted on. The
    /// app happened to be opened late; deliver now rather than dropping it.
    case immediate
    /// Too late to matter, or not this nudge's day.
    case skip
}

// MARK: - TrainingNudgePolicy

/// Every judgement the three remaining A9 notifications make, and no plumbing.
///
/// Split from `NotificationService` the way `HeatAdaptationPolicy` is split from
/// `HeatAdvisoryService`: the copy, the `UNUserNotificationCenter` calls and the
/// authorization check live on the service, and the decisions — is there a streak worth
/// protecting, has the plan run away, what did the week come to, is it too late to say so
/// — live here, pure and injectable, so they are reachable from a test without a device.
enum TrainingNudgePolicy {

    // MARK: Slots

    /// The evening slot for the streak nudge and the missed-workout push.
    ///
    /// Late enough that "you haven't run today" is true rather than premature, early
    /// enough that a runner who wants to save the streak still can.
    static let eveningNudgeHour = 18

    /// Past this hour the evening nudge is dropped rather than delivered late. A push
    /// telling somebody to go for a run at 22:30 is one they cannot act on, and the
    /// notification they turn the whole feature off over.
    static let eveningNudgeCutoffHour = 21

    /// Sunday evening, after the week's last run is realistically in.
    static let weeklyRecapHour = 19

    /// Past this hour the recap waits for next week rather than arriving at midnight.
    static let weeklyRecapCutoffHour = 22

    /// Gregorian `.weekday` for Sunday — the last day of a Monday-anchored week, so the
    /// recap covers the week it is sent in rather than looking back over a boundary.
    static let weeklyRecapWeekday = 1

    /// Below this, a "streak" is two days and a coincidence. Nudging somebody to protect
    /// it is how a notification stops being a favour.
    static let minimumStreakToProtect = 3

    // MARK: Evening nudge

    /// The single nudge for tonight's slot, or `nil` when there is nothing to say.
    ///
    /// Order is by expiry, not by importance: a streak ends at midnight and cannot be
    /// said tomorrow, whereas a plan that has run away will still have run away in the
    /// morning.
    static func eveningNudge(
        streak: StreakGoalService.StreakSummary,
        plan: TrainingPlan?,
        missedPromptFlaggedAt: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TrainingNudge? {
        if let nudge = streakNudge(for: streak) {
            return .streak(nudge)
        }
        if let info = missedWorkoutNudge(
            in: plan,
            flaggedAt: missedPromptFlaggedAt,
            now: now,
            calendar: calendar
        ) {
            return .missedWorkouts(info)
        }
        return nil
    }

    /// Tomorrow evening's streak nudge, armed today once today's run is in.
    ///
    /// `eveningNudge` only covers *tonight*, so a runner who skips tomorrow and never
    /// opens the app tomorrow — the person the nudge is for — got nothing: the app has
    /// no background wake of its own to arm tomorrow's slot. Arming it a day ahead
    /// closes that. The pending request is taken back down when tomorrow's run
    /// arrives, in the foreground or through a background HealthKit sync.
    ///
    /// The streak as it stands today is the streak tomorrow's midnight would end, so
    /// the number is `current`, not `current + 1`.
    static func tomorrowStreakNudge(for streak: StreakGoalService.StreakSummary) -> StreakNudge? {
        guard streak.isActiveToday, streak.current >= minimumStreakToProtect else { return nil }
        return StreakNudge(days: streak.current)
    }

    /// Runs to fetch when computing a streak for a nudge. The streak walks backwards a
    /// day at a time, so the sample has to be at least as long as the longest streak it
    /// could need to count: 200 days of running in a row with one run a day.
    static let streakRunSampleSize = 200

    /// A streak worth protecting that today has not yet extended.
    ///
    /// `StreakSummary.current` already anchors at yesterday when today has no run, so the
    /// number here is the streak that is still standing — exactly what tonight's midnight
    /// would end.
    static func streakNudge(for streak: StreakGoalService.StreakSummary) -> StreakNudge? {
        guard !streak.isActiveToday, streak.current >= minimumStreakToProtect else { return nil }
        return StreakNudge(days: streak.current)
    }

    /// The missed-workout push behind the dashboard's recovery card.
    ///
    /// Deliberately the same two gates the card uses (`DashboardView.missedWorkoutInfo`):
    /// `MissedWorkoutDetector`'s trailing streak, and the once-a-week dismissal. A runner
    /// who put the card away on Tuesday has answered the question; sending it to their
    /// Lock Screen on Wednesday is asking it again through a louder channel.
    static func missedWorkoutNudge(
        in plan: TrainingPlan?,
        flaggedAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MissedWorkoutInfo? {
        guard let plan, plan.isActive else { return nil }
        guard let info = MissedWorkoutDetector.detect(in: plan, today: now) else { return nil }
        if let flaggedAt,
           StreakGoalService.startOfWeek(for: flaggedAt, calendar: calendar)
               == StreakGoalService.startOfWeek(for: now, calendar: calendar) {
            return nil
        }
        return info
    }

    // MARK: Weekly recap

    /// The week containing `now`, as a recap — or `nil` when there is nothing to recap.
    ///
    /// A week with no runs in it returns nil: the streak nudge and the missed-workout
    /// push are the surfaces for not having run, and a Sunday banner reading "0 runs,
    /// 0 km" is a scolding rather than a summary.
    ///
    /// Counts runs, not walks (N38) — every other weekly number in the app is a training
    /// number, and a recap that quietly includes the walk to the shops disagrees with the
    /// Progress tab it is summarising.
    static func weeklyRecap(
        for runs: [RunWorkout],
        goalMeters: Double,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WeeklyRecap? {
        let weekStart = StreakGoalService.startOfWeek(for: now, calendar: calendar)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let thisWeek = runs.runsOnly.filter { $0.date >= weekStart && $0.date < weekEnd }
        guard !thisWeek.isEmpty else { return nil }

        return WeeklyRecap(
            weekStart: weekStart,
            runCount: thisWeek.count,
            totalMeters: thisWeek.reduce(0) { $0 + $1.distanceMeters },
            longestRunMeters: thisWeek.map(\.distanceMeters).max() ?? 0,
            goalMeters: max(goalMeters, 0)
        )
    }

    // MARK: Delivery

    /// When tonight's evening nudge should land.
    static func eveningDelivery(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TrainingNudgeDelivery {
        delivery(hour: eveningNudgeHour, cutoffHour: eveningNudgeCutoffHour, now: now, calendar: calendar)
    }

    /// Tomorrow's evening slot, for the streak nudge armed a day ahead.
    static func tomorrowEveningSlot(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        else { return nil }
        return time(hour: eveningNudgeHour, on: tomorrow, calendar: calendar)
    }

    /// When this week's recap should land. `.skip` on any day but Sunday.
    static func weeklyRecapDelivery(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TrainingNudgeDelivery {
        guard calendar.component(.weekday, from: now) == weeklyRecapWeekday else { return .skip }
        return delivery(hour: weeklyRecapHour, cutoffHour: weeklyRecapCutoffHour, now: now, calendar: calendar)
    }

    /// Resolves today's `hour` slot against `now`, with everything past `cutoffHour`
    /// dropped rather than delivered too late to use.
    private static func delivery(
        hour: Int,
        cutoffHour: Int,
        now: Date,
        calendar: Calendar
    ) -> TrainingNudgeDelivery {
        guard
            let slot = time(hour: hour, on: now, calendar: calendar),
            let cutoff = time(hour: cutoffHour, on: now, calendar: calendar)
        else { return .skip }

        if now < slot { return .scheduled(slot) }
        return now < cutoff ? .immediate : .skip
    }

    private static func time(hour: Int, on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)
    }

    // MARK: Period keys

    /// The period a nudge is handled *for* — one evening for the two prods, one week for
    /// the recap. See ``TrainingNudgeLog``.
    static func period(
        for kind: TrainingNudgeKind,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        switch kind {
        case .streak, .missedWorkouts:
            return calendar.startOfDay(for: now)
        case .weeklyRecap:
            return StreakGoalService.startOfWeek(for: now, calendar: calendar)
        }
    }
}

// MARK: - TrainingNudgeLog

/// Remembers which period each nudge has already been handled for.
///
/// Needed only because of the `.immediate` branch. A *scheduled* request carries a stable
/// identifier, so re-arming it on the next foreground replaces the pending one and
/// nothing is duplicated — but an immediate delivery has already left, and without a mark
/// a runner who opens the app twice between 18:00 and 21:00 gets the same push twice.
///
/// Scheduling marks the period too, so a request that has already fired at 18:00 cannot
/// be re-delivered immediately when the app is next opened at 18:30.
enum TrainingNudgeLog {

    static func key(for kind: TrainingNudgeKind) -> String {
        "\(keyPrefix)\(kind.rawValue)"
    }

    static let keyPrefix = "trainingNudge.handledPeriod."

    /// Whether `kind` has already been scheduled or delivered for `period`.
    ///
    /// Compared with `>=` rather than for equality so a mark written in one time zone
    /// still reads as "this period is done" after the device moves.
    static func hasHandled(
        _ kind: TrainingNudgeKind,
        period: Date,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        let stored = defaults.double(forKey: key(for: kind))
        guard stored != 0 else { return false }
        return stored >= period.timeIntervalSince1970
    }

    static func markHandled(
        _ kind: TrainingNudgeKind,
        period: Date,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(period.timeIntervalSince1970, forKey: key(for: kind))
    }

    /// Forgets every mark, so the next foreground is free to nudge again.
    ///
    /// Used when the feature is switched off — leaving today's mark behind would
    /// otherwise make switching it straight back on silent until tomorrow — and by
    /// "Reset All Data", which is meant to leave nothing of the previous install behind.
    static func clearAll(in defaults: UserDefaults = .standard) {
        for kind in TrainingNudgeKind.allCases {
            defaults.removeObject(forKey: key(for: kind))
        }
    }
}
