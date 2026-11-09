import Foundation

// MARK: - YearInRunning

/// The numbers behind the year-in-running recap: one calendar year of running, reduced to
/// the handful of facts a runner would want to share.
///
/// Pure value maths, like `ProgressPeriodStats` and `StreakGoalService`: it takes the runs,
/// a `now` and a `calendar`, and keeps no state, so every figure the recap cards print is
/// unit-testable. The cards and the share images are built on top of this in later steps.
///
/// Rules every figure follows:
/// - Only running counts (`Sequence.runsOnly`): an imported walk is not a run in the
///   runner's year, the same rule the Progress tab and the streak follow (N38).
/// - "Nothing to say" is `nil`, never a zero or an empty string, so a card can be left out
///   rather than printed with a dash. A recap shows only what is true and worth showing.
/// - The year is the calendar year in `calendar`'s time zone, so a run at 23:30 on
///   31 December lands in the year the runner remembers it in.
struct YearInRunning: Equatable, Sendable {

    /// The calendar year, e.g. 2026.
    let year: Int

    /// Whether the year is still running at `now`. The recap is reachable during the year
    /// (so it can be reviewed and shared in December), and the cards then say "so far".
    let isInProgress: Bool

    // MARK: Totals

    let runCount: Int
    let totalMeters: Double
    let totalSeconds: Double
    /// Climb summed over the runs that recorded any; `nil` when none did (treadmill-only
    /// years, or imports with no elevation), so the card is skipped instead of showing 0.
    let elevationGainMeters: Double?
    /// Distinct calendar days with at least one run.
    let activeDays: Int
    /// The longest run of consecutive calendar days with a run, inside this year.
    let longestStreakDays: Int

    // MARK: Highlights

    /// The single longest run of the year.
    let longestRun: RunHighlight?
    /// Distance run in each month, January first; always 12 entries.
    let monthlyMeters: [Double]
    /// The month with the most distance (1 = January), `nil` with no distance at all.
    let biggestMonth: Int?
    /// Fastest run at each standard race distance this year. See `bestEfforts(in:allRuns:)`.
    let bestEfforts: [BestEffort]
    /// How estimated fitness moved across the year, when there is enough to say.
    let fitnessChange: FitnessChange?
    /// When in the day the runner usually ran, when one part of the day clearly leads.
    let usualTimeOfDay: TimeOfDay?

    // MARK: Comparison

    /// Distance run in the previous calendar year; `nil` when there were no runs then (a
    /// new runner, or a new install with no history), so "vs last year" is not shown.
    let previousYearMeters: Double?

    // MARK: Derived

    var averagePaceSecondsPerKm: Double? {
        guard totalMeters > 0, totalSeconds > 0 else { return nil }
        return totalSeconds / totalMeters * 1_000
    }

    /// Distance change against the previous year as a fraction (0.25 = 25% further).
    var changeFromPreviousYear: Double? {
        guard let previousYearMeters, previousYearMeters > 0 else { return nil }
        return (totalMeters - previousYearMeters) / previousYearMeters
    }

    /// Whether there is enough here for a recap worth opening. A runner with one or two
    /// runs gets an encouraging empty state instead of a story of near-empty cards.
    var hasEnoughForRecap: Bool { runCount >= Self.minimumRunsForRecap }

    static let minimumRunsForRecap = 3

    // MARK: Nested types

    struct RunHighlight: Equatable, Sendable {
        let runID: UUID
        let date: Date
        let meters: Double
        let seconds: Double
    }

    /// The year's fastest effort at one race distance.
    struct BestEffort: Equatable, Sendable, Identifiable {
        let distance: RaceDistance
        let run: RunHighlight
        /// Whether this is also the fastest the runner has ever run this distance in
        /// Stride (all runs up to the end of this year), i.e. a personal best set this year.
        let isPersonalBest: Bool

        var id: RaceDistance { distance }
    }

    enum RaceDistance: String, CaseIterable, Sendable {
        case fiveK = "5K"
        case tenK = "10K"
        case half = "Half marathon"
        case marathon = "Marathon"

        var meters: Double {
            switch self {
            case .fiveK: 5_000
            case .tenK: 10_000
            case .half: 21_097.5
            case .marathon: 42_195
            }
        }
    }

    /// Estimated VDOT early in the year against late in the year.
    struct FitnessChange: Equatable, Sendable {
        let startVDOT: Double
        let endVDOT: Double
        var delta: Double { endVDOT - startVDOT }
    }

    enum TimeOfDay: String, Sendable {
        case earlyMorning, morning, afternoon, evening, night

        /// The part of the day an hour (0–23) belongs to.
        init(hour: Int) {
            switch hour {
            case 4..<8: self = .earlyMorning
            case 8..<12: self = .morning
            case 12..<17: self = .afternoon
            case 17..<21: self = .evening
            default: self = .night
            }
        }

        /// How a card names it: "You're an early-morning runner".
        var runnerLabel: String {
            switch self {
            case .earlyMorning: "early-morning"
            case .morning: "morning"
            case .afternoon: "afternoon"
            case .evening: "evening"
            case .night: "night"
            }
        }
    }
}

// MARK: - Building

extension YearInRunning {

    /// A best effort counts only when the run was close to the race distance itself: at
    /// least 98% of it (GPS noise, as `ProgressStatsService.minDistanceRatio`) and at most
    /// 5% over. A 10 km run is not a 5K, and printing its whole time under "5K" (or a
    /// Riegel guess at its first 5 km) would put a number on a share card the runner
    /// never ran.
    static let bestEffortMaxDistanceRatio = 1.05

    /// Fitness change needs this many quality-effort VDOT samples in the year, so it
    /// compares a few runs at each end rather than one tempo against one race.
    static let minimumVDOTSamples = 6
    /// Samples averaged at each end of the year.
    static let vdotSamplesPerEnd = 3

    /// The share of runs the leading part of the day must beat before the recap calls
    /// the runner "a morning runner". Strictly more than half, so there is never a tie.
    static let usualTimeOfDayShare = 0.5

    static let eligibleBestEffortTypes: Set<WorkoutType> = [.easy, .tempo, .interval, .longRun, .race]

    /// Builds the recap for `year` from every run the runner has.
    ///
    /// - Parameters:
    ///   - allRuns: every recorded workout, any order; walks and cross-training are dropped.
    ///   - year: the calendar year to summarise.
    ///   - now: the moment the recap is read, which decides `isInProgress`.
    ///   - calendar: the calendar and time zone that decide which year and day a run is in.
    static func make(
        from allRuns: [RunWorkout],
        year: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> YearInRunning {
        let runs = allRuns.runsOnly.filter { $0.distanceMeters > 0 }
        let yearRuns = runs.filter { calendar.component(.year, from: $0.date) == year }
        let previousYearRuns = runs.filter { calendar.component(.year, from: $0.date) == year - 1 }

        let totalMeters = yearRuns.reduce(0) { $0 + $1.distanceMeters }
        let totalSeconds = yearRuns.reduce(0) { $0 + max($1.durationSeconds, 0) }

        let climbs = yearRuns.compactMap(\.elevationGainMeters).filter { $0 > 0 }
        let elevation = climbs.isEmpty ? nil : climbs.reduce(0, +)

        let days = Set(yearRuns.map { calendar.startOfDay(for: $0.date) })

        var monthly = Array(repeating: 0.0, count: 12)
        for run in yearRuns {
            let month = calendar.component(.month, from: run.date)
            if (1...12).contains(month) { monthly[month - 1] += run.distanceMeters }
        }
        let biggestMonth: Int? = {
            guard let best = monthly.max(), best > 0,
                  let index = monthly.firstIndex(of: best) else { return nil }
            return index + 1
        }()

        let longestRun = yearRuns
            .max { lhs, rhs in
                // Ties go to the earlier run, so the result doesn't depend on input order.
                lhs.distanceMeters == rhs.distanceMeters
                    ? lhs.date > rhs.date
                    : lhs.distanceMeters < rhs.distanceMeters
            }
            .map(highlight)

        let previousYearMeters = previousYearRuns.isEmpty
            ? nil
            : previousYearRuns.reduce(0) { $0 + $1.distanceMeters }

        let isInProgress: Bool = {
            guard let start = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
                return false
            }
            return now < start
        }()

        return YearInRunning(
            year: year,
            isInProgress: isInProgress,
            runCount: yearRuns.count,
            totalMeters: totalMeters,
            totalSeconds: totalSeconds,
            elevationGainMeters: elevation,
            activeDays: days.count,
            longestStreakDays: longestStreak(in: days, calendar: calendar),
            longestRun: longestRun,
            monthlyMeters: monthly,
            biggestMonth: biggestMonth,
            bestEfforts: bestEfforts(in: yearRuns, allRuns: runs, year: year, calendar: calendar),
            fitnessChange: fitnessChange(in: yearRuns),
            usualTimeOfDay: usualTimeOfDay(in: yearRuns, calendar: calendar),
            previousYearMeters: previousYearMeters
        )
    }

    // MARK: Pieces

    /// Longest stretch of consecutive calendar days in `days` (each a start of day).
    static func longestStreak(in days: Set<Date>, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var longest = 1
        var current = 1
        for index in 1..<sorted.count {
            if let next = calendar.date(byAdding: .day, value: 1, to: sorted[index - 1]),
               calendar.isDate(next, inSameDayAs: sorted[index]) {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
        }
        return longest
    }

    /// The fastest run at each race distance this year, and whether it is an all-time best.
    ///
    /// "All-time" means every run up to the end of `year`, so a 2025 recap opened in 2027
    /// still says what was a best *then*. A tie with an earlier run is not a new best.
    static func bestEfforts(
        in yearRuns: [RunWorkout],
        allRuns: [RunWorkout],
        year: Int,
        calendar: Calendar
    ) -> [BestEffort] {
        let earlierRuns = allRuns.filter { calendar.component(.year, from: $0.date) < year }

        return RaceDistance.allCases.compactMap { distance in
            guard let best = fastest(at: distance, in: yearRuns) else { return nil }
            // Compared by pace, the same measure `fastest` ranks by, since the runs are
            // not exactly the same length.
            let isPersonalBest = fastest(at: distance, in: earlierRuns).map {
                pace(best) < pace($0)
            } ?? true
            return BestEffort(distance: distance, run: highlight(best), isPersonalBest: isPersonalBest)
        }
    }

    /// The quickest run that was the race distance (see `bestEffortMaxDistanceRatio`).
    /// Ranked by time scaled to exactly the distance, so a run 3% long isn't penalised.
    private static func fastest(at distance: RaceDistance, in runs: [RunWorkout]) -> RunWorkout? {
        let target = distance.meters
        let candidates = runs.filter { run in
            run.durationSeconds > 0
                && eligibleBestEffortTypes.contains(run.workoutType)
                && run.distanceMeters >= target * ProgressStatsService.minDistanceRatio
                && run.distanceMeters <= target * bestEffortMaxDistanceRatio
        }
        return candidates.min { lhs, rhs in
            pace(lhs) == pace(rhs) ? lhs.date < rhs.date : pace(lhs) < pace(rhs)
        }
    }

    /// Seconds per metre; only called on runs with a positive distance.
    private static func pace(_ run: RunWorkout) -> Double {
        run.durationSeconds / run.distanceMeters
    }

    /// Mean VDOT of the first few quality efforts against the last few. `nil` until the
    /// year has `minimumVDOTSamples`, so a single hard run can't claim a trend.
    static func fitnessChange(in yearRuns: [RunWorkout]) -> FitnessChange? {
        let samples = ProgressPeriodStats.vdotSamples(for: yearRuns)
        guard samples.count >= minimumVDOTSamples else { return nil }
        let early = samples.prefix(vdotSamplesPerEnd).map(\.vdot)
        let late = samples.suffix(vdotSamplesPerEnd).map(\.vdot)
        return FitnessChange(
            startVDOT: early.reduce(0, +) / Double(early.count),
            endVDOT: late.reduce(0, +) / Double(late.count)
        )
    }

    /// The part of the day that holds more than `usualTimeOfDayShare` of the year's runs.
    /// Needs `minimumRunsForRecap` runs, so two morning runs don't make a habit.
    static func usualTimeOfDay(in yearRuns: [RunWorkout], calendar: Calendar) -> TimeOfDay? {
        guard yearRuns.count >= minimumRunsForRecap else { return nil }
        var counts: [TimeOfDay: Int] = [:]
        for run in yearRuns {
            counts[TimeOfDay(hour: calendar.component(.hour, from: run.date)), default: 0] += 1
        }
        guard let leader = counts.max(by: { $0.value < $1.value }),
              Double(leader.value) / Double(yearRuns.count) > usualTimeOfDayShare else { return nil }
        return leader.key
    }

    private static func highlight(_ run: RunWorkout) -> RunHighlight {
        RunHighlight(runID: run.id, date: run.date, meters: run.distanceMeters, seconds: run.durationSeconds)
    }
}
