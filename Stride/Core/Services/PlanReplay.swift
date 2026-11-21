import Foundation

// MARK: - PlanReplay

/// A finished plan, start to finish, as numbers worth sharing: what it was, how much of it
/// got done, how far, the longest run, the race, and whether fitness rose.
///
/// The end of a plan is the moment a runner is proudest of it, and the story cards this
/// feeds (``PlanReplayCards``) are made to be posted, so friends see what a Stride plan
/// looks like from start to race day. Built from ``PlanSummary`` so the replay and the
/// plan's own summary card never disagree about a number.
struct PlanReplay: Equatable, Sendable {

    struct RaceResult: Equatable, Sendable {
        let date: Date
        let meters: Double
        let seconds: Double
    }

    struct LongestRun: Equatable, Sendable {
        let date: Date
        let meters: Double
        let seconds: Double
    }

    /// The plan's name as a runner reads it: "Half Marathon", "Chicago Marathon".
    let title: String
    let weeks: Int
    let sessionsPlanned: Int
    let sessionsDone: Int
    let runCount: Int
    let runMeters: Double
    let runSeconds: Double
    let strengthSessions: Int
    let longestRun: LongestRun?
    let race: RaceResult?
    let fitnessChange: YearInRunning.FitnessChange?

    /// A replay needs a few runs to say anything; fewer and the cards would be mostly
    /// empty, which is not something anyone posts.
    var hasEnoughForReplay: Bool { runCount >= YearInRunning.minimumRunsForRecap }

    var averagePaceSecondsPerKm: Double? {
        guard runMeters > 0, runSeconds > 0 else { return nil }
        return runSeconds / runMeters * 1_000
    }

    /// When a plan can be replayed: once its last day has passed. A pregnancy plan has no
    /// replay; its numbers are about a pregnancy, not a goal reached, and are not for a
    /// public post.
    static func isAvailable(endDate: Date, isPregnancyPlan: Bool, now: Date = Date()) -> Bool {
        !isPregnancyPlan && endDate < now
    }
}

extension PlanReplay {

    /// The replay of `plan`. The race is the run linked to the plan's race day, or failing
    /// that any run of the race type in the plan; fitness is the year recap's measure,
    /// taken over the plan's runs.
    static func make(from plan: TrainingPlan, now: Date = Date()) -> PlanReplay {
        let summary = PlanSummaryService.summary(for: plan, now: now)
        let scheduled = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }
        let runs = scheduled.compactMap(\.completedWorkout).runsOnly
            .sorted { $0.date < $1.date }

        let raceRun = scheduled
            .first { $0.workoutType == .race && $0.completedWorkout != nil }?
            .completedWorkout
            ?? runs.last { $0.workoutType == .race }
        let longest = runs.max { $0.distanceMeters < $1.distanceMeters }

        return PlanReplay(
            title: plan.displayTitle,
            weeks: summary.totalWeeks,
            sessionsPlanned: summary.scheduledCount,
            sessionsDone: summary.completedCount,
            runCount: summary.completedRunCount,
            runMeters: summary.completedDistanceMeters,
            runSeconds: runs.reduce(0) { $0 + max($1.durationSeconds, 0) },
            strengthSessions: summary.completedStrengthCount,
            longestRun: longest.map {
                LongestRun(date: $0.date, meters: $0.distanceMeters, seconds: $0.durationSeconds)
            },
            race: raceRun.flatMap { run in
                guard run.distanceMeters > 0, run.durationSeconds > 0 else { return nil }
                return RaceResult(date: run.date, meters: run.distanceMeters, seconds: run.durationSeconds)
            },
            fitnessChange: YearInRunning.fitnessChange(in: runs)
        )
    }
}

// MARK: - PlanReplayCards

/// Turns a ``PlanReplay`` into story cards, drawn by the year recap's card view so the two
/// look like one family. Like the year recap, a card whose numbers have nothing to say is
/// left out, and fitness appears only when it went up.
enum PlanReplayCards {

    static func make(
        from replay: PlanReplay,
        unit: UnitPreference,
        calendar: Calendar = .current
    ) -> [YearRecapCard] {
        guard replay.hasEnoughForReplay else { return [] }
        let eyebrow = String(localized: "\(replay.title) plan", comment: "Plan Replay card eyebrow").uppercased()

        var cards: [YearRecapCard] = []

        cards.append(YearRecapCard(
            kind: .cover,
            eyebrow: "STRIDE",
            headline: weeks(replay.weeks),
            caption: String(localized: "My \(replay.title) plan, start to finish", comment: "Plan Replay cover caption")
        ))

        if let race = replay.race {
            cards.append(YearRecapCard(
                kind: .race,
                eyebrow: eyebrow,
                headline: race.seconds.durationString,
                caption: String(
                    localized: "Race day, \(YearRecapCards.dayMonth(race.date, calendar: calendar)).",
                    comment: "Plan Replay race card caption"
                ),
                stats: [
                    YearRecapCard.Stat(label: "Distance", value: race.meters.distanceString(unit: unit)),
                    YearRecapCard.Stat(label: "Pace", value: (race.seconds / race.meters * 1_000).paceString(unit: unit)),
                ]
            ))
        }

        var distanceStats = [YearRecapCard.Stat(label: "Runs", value: replay.runCount.formatted())]
        distanceStats.append(YearRecapCard.Stat(label: "Time", value: YearRecapCards.hoursString(replay.runSeconds)))
        if let pace = replay.averagePaceSecondsPerKm {
            distanceStats.append(YearRecapCard.Stat(label: "Avg pace", value: pace.paceString(unit: unit)))
        }
        cards.append(YearRecapCard(
            kind: .distance,
            eyebrow: eyebrow,
            headline: YearRecapCards.wholeDistance(replay.runMeters, unit: unit),
            caption: String(localized: "Run in training.", comment: "Plan Replay distance caption"),
            stats: distanceStats
        ))

        if replay.sessionsPlanned > 0 {
            var stats = [YearRecapCard.Stat(label: "Weeks", value: replay.weeks.formatted())]
            if replay.strengthSessions > 0 {
                stats.append(YearRecapCard.Stat(label: "Strength", value: replay.strengthSessions.formatted()))
            }
            cards.append(YearRecapCard(
                kind: .consistency,
                eyebrow: eyebrow,
                headline: "\(replay.sessionsDone) of \(replay.sessionsPlanned)",
                caption: consistencyLine(done: replay.sessionsDone, planned: replay.sessionsPlanned),
                stats: stats
            ))
        }

        if let longest = replay.longestRun, longest.meters > 0 {
            cards.append(YearRecapCard(
                kind: .longestRun,
                eyebrow: eyebrow,
                headline: longest.meters.distanceString(unit: unit),
                caption: String(
                    localized: "My longest run of the plan, on \(YearRecapCards.dayMonth(longest.date, calendar: calendar)).",
                    comment: "Plan Replay longest run caption"
                ),
                stats: [
                    YearRecapCard.Stat(label: "Time", value: longest.seconds.durationString),
                    YearRecapCard.Stat(
                        label: "Pace",
                        value: (longest.seconds / longest.meters * 1_000).paceString(unit: unit)
                    ),
                ]
            ))
        }

        if let change = replay.fitnessChange, change.startVDOT > 0 {
            let percent = change.delta / change.startVDOT * 100
            if percent >= YearRecapCards.minimumFitnessGainPercent {
                cards.append(YearRecapCard(
                    kind: .fitness,
                    eyebrow: eyebrow,
                    headline: "+\(Int(percent.rounded()))%",
                    caption: String(
                        localized: "Fitter than I started, going by my hardest sessions.",
                        comment: "Plan Replay fitness caption"
                    ),
                    stats: [
                        YearRecapCard.Stat(
                            label: "Fitness score",
                            value: String(format: "%.1f → %.1f", change.startVDOT, change.endVDOT)
                        ),
                    ]
                ))
            }
        }

        cards.append(YearRecapCard(
            kind: .outro,
            eyebrow: eyebrow,
            headline: String(localized: "Planned by Stride", comment: "Plan Replay outro headline"),
            caption: String(
                localized: "Every session, adapted as I went. \(StrideLinks.landingPageDisplay)",
                comment: "Plan Replay outro caption"
            )
        ))

        return cards
    }

    static func weeks(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 week", comment: "Plan Replay cover")
            : String(localized: "\(count) weeks", comment: "Plan Replay cover")
    }

    /// The line under "52 of 56": honest about a plan that slipped, never a telling-off.
    static func consistencyLine(done: Int, planned: Int) -> String {
        guard planned > 0 else { return "" }
        let share = Double(done) / Double(planned)
        switch share {
        case 1...:
            return String(localized: "Sessions done. Every single one.", comment: "Plan Replay consistency caption")
        case 0.8..<1:
            return String(localized: "Sessions done. Nearly all of them.", comment: "Plan Replay consistency caption")
        default:
            return String(localized: "Sessions done, around everything else.", comment: "Plan Replay consistency caption")
        }
    }
}
