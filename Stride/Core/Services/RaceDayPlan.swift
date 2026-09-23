import Foundation

// MARK: - RacePhase

/// Where the runner stands relative to their goal race.
///
/// Deliberately not folded into ``CoachSituation``'s race cases. That type answers "what
/// is the one thing worth saying on the dashboard today", so it only needs to know about
/// race week and race morning and treats everything else as not-a-race. The hub is on
/// screen for the whole arc — the months before the taper, the morning itself, and the
/// days after the finish — so it needs a value that covers all of it.
enum RacePhase: Equatable, Sendable {

    /// Further out than race week.
    case building(daysOut: Int)
    /// Inside the final week, race day excluded.
    case raceWeek(daysOut: Int)
    /// Race morning.
    case raceDay
    /// The race date has passed, whether or not a result has been recorded yet.
    case finished(daysSince: Int)

    /// Whole days until the race; nil once the date has passed.
    var daysOut: Int? {
        switch self {
        case .building(let days), .raceWeek(let days): return days
        case .raceDay:                                 return 0
        case .finished:                                return nil
        }
    }

    /// Whether the race is still ahead of the runner.
    var isBeforeRace: Bool {
        switch self {
        case .building, .raceWeek: return true
        case .raceDay, .finished:  return false
        }
    }
}

// MARK: - RaceGoal

/// One of the three finish times a runner takes to the start line.
///
/// The ladder is built *down* from the time the runner committed to, not up from it. A
/// runner who typed "3:30 marathon" into onboarding has already told us their ambitious
/// number — presenting that as the middle rung and inventing a faster one above it would
/// be the app raising their goal for them on race morning, which is the one morning it
/// has no business doing that. So the goal they set is the A goal, and B and C are the
/// two ways a race still goes well when the day is merely good, or not theirs at all.
struct RaceGoal: Identifiable, Equatable, Sendable {

    enum Tier: String, CaseIterable, Sendable {
        case a, b, c

        var localizedName: String {
            switch self {
            case .a: return String(localized: "A goal", comment: "Race goal tier")
            case .b: return String(localized: "B goal", comment: "Race goal tier")
            case .c: return String(localized: "C goal", comment: "Race goal tier")
            }
        }

        /// What the tier means, in the terms a runner would put it in themselves.
        var localizedSubtitle: String {
            switch self {
            case .a: return String(localized: "The day you trained for", comment: "Race goal tier meaning")
            case .b: return String(localized: "A good day, not a perfect one", comment: "Race goal tier meaning")
            case .c: return String(localized: "Whatever the day brings, finish it", comment: "Race goal tier meaning")
            }
        }

        /// How much slower than the A goal this rung sits, as a fraction.
        ///
        /// Three and seven per cent, applied to the finish time rather than to the pace —
        /// the two are the same arithmetic at even pace, and stating it on the time keeps
        /// the rungs the round-ish numbers a runner recognises. On a 3:30 marathon that is
        /// 3:36:18 and 3:44:42; on a 25:00 5 K, 25:45 and 26:45. Both read as the two
        /// answers to "what would still have been a good day", which is what the rungs are
        /// for. Nothing about the runner's own data moves them: a ladder that narrowed
        /// when training went well would be a prediction, and the prediction is reported
        /// separately as ``RaceDayPlan/predictedFinishSeconds``.
        var slowdown: Double {
            switch self {
            case .a: return 0
            case .b: return 0.03
            case .c: return 0.07
            }
        }
    }

    let tier: Tier
    let finishSeconds: TimeInterval
    /// The even pace that finish time implies, in seconds per kilometre.
    let paceSecondsPerKm: Double

    var id: String { tier.rawValue }
}

// MARK: - RaceSplit

/// One row of the goal-pace split table: where a marker is, and what the clock should
/// read as the runner crosses it.
struct RaceSplit: Identifiable, Equatable, Sendable {

    /// 1-based marker number, counted in the runner's own distance unit.
    let marker: Int
    /// Cumulative distance at this marker, in metres.
    let distanceMeters: Double
    /// True for the short final segment a race distance leaves over — the marathon's last
    /// 195 m, a half's last 97.5 m. It is drawn as the finish rather than as a marker.
    let isPartial: Bool
    /// Cumulative elapsed time at this marker, at the goal's even pace.
    let elapsedSeconds: TimeInterval

    var id: Int { marker }
}

// MARK: - RaceTaperStatus

/// How far into the taper the plan has brought the runner, as of this week.
struct RaceTaperStatus: Equatable, Sendable {

    let phase: TrainingPhase
    let weekNumber: Int
    let totalWeeks: Int
    /// What this week asks for, in kilometres.
    let plannedKm: Double
    /// The biggest week the plan ever asked for, in kilometres.
    let peakKm: Double

    /// How far below the peak week this one sits, as a fraction. Zero while the plan is
    /// still building — a week *above* the previous peak is not a negative taper.
    var reductionFromPeak: Double {
        guard peakKm > 0, plannedKm < peakKm else { return 0 }
        return (peakKm - plannedKm) / peakKm
    }
}

// MARK: - RaceResult

/// What actually happened, once the race run is in the log.
struct RaceResult: Equatable, Sendable {

    let finishSeconds: TimeInterval
    let distanceMeters: Double
    let paceSecondsPerKm: Double
    /// Seconds inside the A goal — negative when the finish came in outside it. Nil when
    /// no goal time was ever set, in which case the result is simply reported.
    let secondsInsideGoal: TimeInterval?
    /// The most ambitious rung the finish beat, or nil when it came in outside all three.
    let tierAchieved: RaceGoal.Tier?
}

// MARK: - RaceDayPlan

/// Everything the race-day hub shows, resolved from the plan and the profile.
///
/// Pure, with an injectable `now` and `calendar`, like ``CoachSituation`` and
/// ``WidgetSnapshotBuilder``. The view picks a goal rung and a unit; this decides
/// everything else, so the countdown, the ladder, the splits and the result are all
/// assertable without a screen.
struct RaceDayPlan: Equatable, Sendable {

    let raceName: String
    let raceType: RaceType
    let distanceMeters: Double
    /// Start of the race day. The app stores a date, not a start time — see
    /// ``splits(for:unit:)`` for what that does and does not let the hub say.
    let raceDate: Date
    let phase: RacePhase
    /// The three rungs, or empty when no goal time has been set.
    let goals: [RaceGoal]
    /// What recent fitness predicts over the race distance, when there is enough history
    /// to derive a VDOT. Reported beside the ladder rather than folded into it: a goal is
    /// a decision the runner made and a prediction is a measurement, and a hub that
    /// quietly rewrote the first with the second would be arguing with them.
    let predictedFinishSeconds: TimeInterval?
    let taper: RaceTaperStatus?
    let result: RaceResult?

    /// The rung the runner set for themselves.
    var goal: RaceGoal? { goals.first { $0.tier == .a } }

    /// Whether the race is near enough — or recent enough — to earn a place on the
    /// dashboard.
    ///
    /// The Plan tab carries the countdown all season, because that is the screen about
    /// the plan. The dashboard is the screen about today, and a marathon in March is not
    /// today in October. Two weeks out is roughly where the taper starts mattering on a
    /// standard plan, and the card stays for a few days afterwards so the result can
    /// arrive with the watch sync rather than the race vanishing the moment it is run.
    var deservesDashboardPlacement: Bool {
        switch phase {
        case .building(let days): return days <= Self.dashboardLeadDays
        case .raceWeek, .raceDay: return true
        case .finished(let days): return days <= Self.dashboardAfterDays
        }
    }
}

// MARK: - Resolution

extension RaceDayPlan {

    /// A race this many days out or nearer is race week. Shared with ``CoachSituation`` so
    /// the dashboard's race-week card and the hub's countdown cannot disagree about when
    /// race week began.
    static var raceWeekWindowDays: Int { CoachSituation.raceWeekWindowDays }

    /// How far back fitness is sampled for the predicted finish.
    static let fitnessLookbackWeeks = 8

    /// How many days before the race the dashboard starts carrying the countdown.
    static let dashboardLeadDays = 14

    /// How many days after it the dashboard keeps carrying it.
    static let dashboardAfterDays = 3

    /// Distance below which a leftover final segment is not worth a row: an exact race
    /// distance leaves nothing over, and GPS-rounded ones leave metres.
    static let partialSplitThresholdMeters = 10.0

    /// Fraction of the race distance a run must cover before it is taken for the race
    /// itself. Only the unlinked path needs it — a run the plan's own race day is linked
    /// to is the race by construction — and it is what stops a race-morning shakeout
    /// being reported as the result.
    static let resultDistanceRatio = 0.95

    /// Resolves the hub, or nil when there is no goal race to build one from.
    ///
    /// - Parameters:
    ///   - profile: the runner's profile, which carries the race when no plan does.
    ///   - plan: the active plan. Its race wins over the profile's, because the plan is
    ///     what the runner is actually executing.
    ///   - runs: recent runs in any order, for the fitness prediction and the result.
    static func resolve(
        profile: UserProfile?,
        plan: TrainingPlan?,
        runs: [RunWorkout] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RaceDayPlan? {
        // A pregnancy plan carries `.maintainFitness` and has no race to peak on by
        // design, and a stale `raceDate` left on the profile from a plan before it must
        // not resurrect one behind the runner's back (see `PlanKind`).
        if let plan, plan.isPregnancyPlan { return nil }

        guard let identity = RaceIdentity(profile: profile, plan: plan) else { return nil }
        guard let resolvedPhase = Self.phase(
            forRaceDate: identity.date,
            now: now,
            calendar: calendar
        ) else { return nil }

        let ladder = Self.goals(
            forGoalSeconds: identity.goalSeconds,
            distanceMeters: identity.distanceMeters
        )

        return RaceDayPlan(
            raceName: identity.name,
            raceType: identity.type,
            distanceMeters: identity.distanceMeters,
            raceDate: identity.date,
            phase: resolvedPhase,
            goals: ladder,
            predictedFinishSeconds: Self.predictedFinishSeconds(
                runs: runs,
                profile: profile,
                distanceMeters: identity.distanceMeters,
                now: now
            ),
            taper: Self.taperStatus(plan: plan, now: now, calendar: calendar),
            result: Self.result(
                plan: plan,
                runs: runs,
                raceDate: identity.date,
                distanceMeters: identity.distanceMeters,
                goals: ladder,
                calendar: calendar
            )
        )
    }

    /// Which side of the race today falls on.
    static func phase(forRaceDate raceDate: Date, now: Date, calendar: Calendar) -> RacePhase? {
        guard let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: raceDate)
        ).day else { return nil }

        if days < 0 { return .finished(daysSince: -days) }
        if days == 0 { return .raceDay }
        return days <= raceWeekWindowDays ? .raceWeek(daysOut: days) : .building(daysOut: days)
    }

    /// The three rungs for a goal time, or empty when there is no goal to build them from.
    static func goals(forGoalSeconds seconds: TimeInterval, distanceMeters: Double) -> [RaceGoal] {
        guard seconds > 0, seconds.isFinite, distanceMeters > 0 else { return [] }
        return RaceGoal.Tier.allCases.map { tier in
            let finish = seconds * (1 + tier.slowdown)
            return RaceGoal(
                tier: tier,
                finishSeconds: finish,
                paceSecondsPerKm: finish / (distanceMeters / 1_000)
            )
        }
    }

    /// What recent fitness says the runner is worth over the race distance.
    ///
    /// Sampled from quality efforts only, via ``ProgressStatsService/estimatedVDOT(for:)``
    /// — the same restriction the VO₂ trend and the plan's own adaptation use, and for the
    /// same reason: an easy run is paced below what the runner could do, so predicting a
    /// race from one predicts a slower race every time they train properly. Falls back to
    /// the profile's own 5 K estimate so a runner who has logged nothing hard still gets a
    /// number, and returns nil when there is neither.
    static func predictedFinishSeconds(
        runs: [RunWorkout],
        profile: UserProfile?,
        distanceMeters: Double,
        now: Date
    ) -> TimeInterval? {
        guard distanceMeters > 0 else { return nil }

        let cutoff = now.adding(weeks: -fitnessLookbackWeeks)
        let sampled = runs.runsOnly
            .filter { $0.date >= cutoff && $0.date <= now }
            .compactMap { ProgressStatsService.estimatedVDOT(for: $0) }

        guard let vdot = sampled.max() ?? profile?.baselineVDOT, vdot > 20, vdot.isFinite else { return nil }

        let predicted = PaceCalculatorService.predictedTime(vdot: vdot, distanceMeters: distanceMeters)
        return predicted.isFinite && predicted > 0 ? predicted : nil
    }

    /// Where this week sits against the plan's biggest one.
    ///
    /// Resolves the current week here rather than through ``TrainingPlan/currentWeek``,
    /// which reads `Date()` directly and so cannot be pinned by a test.
    static func taperStatus(plan: TrainingPlan?, now: Date, calendar: Calendar) -> RaceTaperStatus? {
        guard let plan else { return nil }
        let weeks = plan.weeks ?? []
        let today = calendar.startOfDay(for: now)
        let current = weeks.first {
            calendar.startOfDay(for: $0.startDate) <= today && calendar.startOfDay(for: $0.endDate) >= today
        }
        guard let current, let peak = weeks.map(\.targetDistanceKm).max() else { return nil }

        return RaceTaperStatus(
            phase: current.phase,
            weekNumber: current.weekNumber,
            totalWeeks: weeks.count,
            plannedKm: current.targetDistanceKm,
            peakKm: peak
        )
    }

    /// The race as it was actually run, once the run is in the log.
    ///
    /// There is no manual "log a result" path in the app and this deliberately does not
    /// add one: a race is recorded the way every other run is — tracked in the app, or
    /// imported from Health once the watch syncs — so the hub waits for that run rather
    /// than asking the runner to type a time it will shortly be told.
    static func result(
        plan: TrainingPlan?,
        runs: [RunWorkout],
        raceDate: Date,
        distanceMeters: Double,
        goals: [RaceGoal],
        calendar: Calendar
    ) -> RaceResult? {
        let scheduledRace = (plan?.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .first { $0.workoutType == .race && calendar.isDate($0.scheduledDate, inSameDayAs: raceDate) }
        let linked = scheduledRace?.completedWorkout

        // Nothing links a race imported from Health to the plan's race day, so the
        // fallback is the longest run recorded that day — held to most of the race
        // distance, or a shakeout on race morning would be reported as the race.
        let recorded = runs.runsOnly
            .filter {
                calendar.isDate($0.date, inSameDayAs: raceDate)
                    && $0.distanceMeters >= distanceMeters * resultDistanceRatio
            }
            .max { $0.distanceMeters < $1.distanceMeters }

        guard let run = linked ?? recorded, run.durationSeconds > 0, run.distanceMeters > 0 else { return nil }

        let finish = run.durationSeconds
        let target = goals.first { $0.tier == .a }
        let beaten = goals.filter { finish <= $0.finishSeconds }
        let bestBeaten = beaten.min { $0.finishSeconds < $1.finishSeconds }

        return RaceResult(
            finishSeconds: finish,
            distanceMeters: run.distanceMeters,
            paceSecondsPerKm: finish / (run.distanceMeters / 1_000),
            secondsInsideGoal: target.map { $0.finishSeconds - finish },
            tierAchieved: bestBeaten?.tier
        )
    }
}

// MARK: - Splits

extension RaceDayPlan {

    /// The goal-pace split table for one rung, in the runner's own distance unit.
    ///
    /// Even pace, and only even pace. A negative-split table would be the better race
    /// plan for most runners, but it needs a start time and a course to be worth
    /// printing — the app stores neither — and an invented split pattern read off a
    /// screen at 6 a.m. is worse than an honest one. The race workout's own note already
    /// says to start controlled and race the final third; this is the clock to check
    /// against, not a prescription to run to the second.
    func splits(for goal: RaceGoal, unit: UnitPreference) -> [RaceSplit] {
        Self.splits(
            distanceMeters: distanceMeters,
            paceSecondsPerKm: goal.paceSecondsPerKm,
            unit: unit
        )
    }

    static func splits(
        distanceMeters: Double,
        paceSecondsPerKm: Double,
        unit: UnitPreference
    ) -> [RaceSplit] {
        guard distanceMeters > 0, paceSecondsPerKm > 0, paceSecondsPerKm.isFinite else { return [] }

        let markerMeters = unit == .metric ? 1_000.0 : 1_609.344
        let secondsPerMetre = paceSecondsPerKm / 1_000
        let wholeMarkers = Int(distanceMeters / markerMeters)

        var rows: [RaceSplit] = []
        rows.reserveCapacity(wholeMarkers + 1)

        if wholeMarkers >= 1 {
            for marker in 1...wholeMarkers {
                let cumulative = Double(marker) * markerMeters
                rows.append(
                    RaceSplit(
                        marker: marker,
                        distanceMeters: cumulative,
                        isPartial: false,
                        elapsedSeconds: cumulative * secondsPerMetre
                    )
                )
            }
        }

        let remainder = distanceMeters - Double(wholeMarkers) * markerMeters
        if remainder >= partialSplitThresholdMeters {
            rows.append(
                RaceSplit(
                    marker: wholeMarkers + 1,
                    distanceMeters: distanceMeters,
                    isPartial: true,
                    elapsedSeconds: distanceMeters * secondsPerMetre
                )
            )
        }

        return rows
    }
}

// MARK: - RaceIdentity

/// Which race the hub is about, gathered from whichever of the two sources has it.
///
/// The plan and the profile both carry a race, and they can disagree — a plan built
/// before the runner moved their race date in Settings, say. The plan wins on every
/// field it has, because the plan is the thing whose weeks are being run.
private struct RaceIdentity {

    let name: String
    let type: RaceType
    let distanceMeters: Double
    let date: Date
    let goalSeconds: TimeInterval

    private init(type: RaceType, distanceMeters: Double, date: Date, goalSeconds: TimeInterval, name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmed?.isEmpty == false ? trimmed : nil) ?? type.localizedName
        self.type = type
        self.distanceMeters = distanceMeters
        self.date = date
        self.goalSeconds = goalSeconds
    }

    init?(profile: UserProfile?, plan: TrainingPlan?) {
        if let plan, plan.targetRace.isGoalRace, let date = plan.raceDate, plan.effectiveRaceDistanceMeters > 0 {
            self.init(
                type: plan.targetRace,
                distanceMeters: plan.effectiveRaceDistanceMeters,
                date: date,
                goalSeconds: plan.goalTimeSeconds,
                name: plan.raceName
            )
            return
        }

        if let profile,
           profile.goalRace.isGoalRace,
           let date = profile.raceDate,
           profile.effectiveRaceDistanceMeters > 0 {
            self.init(
                type: profile.goalRace,
                distanceMeters: profile.effectiveRaceDistanceMeters,
                date: date,
                goalSeconds: profile.goalFinishTime,
                name: profile.raceName
            )
            return
        }

        return nil
    }
}
