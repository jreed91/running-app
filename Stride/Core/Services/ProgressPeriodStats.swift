import Foundation

// MARK: - ProgressPeriodStats

/// The Progress tab's period arithmetic: which runs fall in the selected range, what
/// they add up to, how they bucket by week, and the VDOT series the fitness trend plots.
///
/// All of it lived in `ProgressDashboardView`'s body-evaluated properties (D1) — the
/// least tested code in the app, and the kind that fails quietly: an average taken over
/// the wrong denominator, or a "no data" placeholder shown because `nil` and `0` were
/// conflated, looks exactly like a correct number to everyone except the runner who
/// knows what they ran.
///
/// Each aggregate distinguishes "no runs carried this measurement" (`nil`, rendered as
/// `--`) from "the measurement is zero", and each averages only over the runs that
/// actually carried it, rather than dividing by the period's total run count.
///
/// Pure and `Sendable`, in the shape `ProgressStatsService` already established for the
/// per-run maths this composes.
enum ProgressPeriodStats {

    // MARK: Range

    /// The runs within `days` of `now`, newest-first order preserved from the caller.
    ///
    /// The cutoff is a rolling window rather than a calendar boundary, matching what the
    /// range picker promises ("3M" is the last three months, not the last three
    /// calendar months).
    ///
    /// Imported walks are dropped here rather than at the screen (N38). Everything the
    /// Progress tab draws flows through this one function, so this is where "the Progress
    /// tab is about running" is true once instead of at every chart.
    static func runs(in allRuns: [RunWorkout], withinDays days: Int, now: Date = Date()) -> [RunWorkout] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return allRuns.runsOnly.filter { $0.date >= cutoff }
    }

    // MARK: VDOT series

    /// One point on the estimated-VO₂max trend.
    struct VDOTSample: Equatable, Sendable {
        let date: Date
        let vdot: Double
    }

    /// The VDOT samples implied by `runs`, oldest first.
    ///
    /// Only quality efforts produce a sample (`ProgressStatsService.estimatedVDOT`), so
    /// this is usually far shorter than `runs` — and empty for a runner who has logged
    /// nothing but easy miles, which the chart must say rather than plot as a flat line.
    ///
    /// Sorted explicitly: the header reads "the latest VDOT" off the last element, and
    /// the caller's ordering is newest-first, which would have made it the oldest.
    static func vdotSamples(for runs: [RunWorkout]) -> [VDOTSample] {
        runs
            .compactMap { run in
                ProgressStatsService.estimatedVDOT(for: run).map { VDOTSample(date: run.date, vdot: $0) }
            }
            .sorted { $0.date < $1.date }
    }

    // MARK: Weekly buckets

    /// Total distance for one week of the period.
    struct WeeklyDistance: Equatable, Sendable {
        let weekStart: Date
        let meters: Double
    }

    /// `runs` totalled by the week they fall in, oldest week first.
    ///
    /// Weeks start on Monday, per `Date.startOfWeek` — the definition the rest of the
    /// app's weekly maths already uses, so a training week and a chart bar cover the
    /// same seven days.
    ///
    /// Distance stays in metres: the chart converts once, at the point it knows the
    /// runner's unit preference, instead of every producer converting for itself.
    static func weeklyDistances(for runs: [RunWorkout]) -> [WeeklyDistance] {
        var byWeek: [Date: Double] = [:]
        for run in runs {
            byWeek[run.date.startOfWeek, default: 0] += run.distanceMeters
        }
        return byWeek
            .map { WeeklyDistance(weekStart: $0.key, meters: $0.value) }
            .sorted { $0.weekStart < $1.weekStart }
    }

    // MARK: Easy pace trend

    /// What the pace card plots: easy-run paces and the typical one each week.
    ///
    /// The card used to join every run's average pace into one line. A tempo, an interval
    /// session (recoveries included), a long run and a race each sit at a different pace by
    /// design, so the line zigzagged with the week's mix of sessions and never answered
    /// "am I getting faster?". Holding the effort steady is what makes pace comparable, so
    /// only easy and long runs count here; quality sessions already feed the VDOT card.
    struct EasyPaceTrend: Equatable, Sendable {
        struct Run: Equatable, Sendable, Identifiable {
            let id: UUID
            let date: Date
            let paceSecondsPerKm: Double
            let workoutType: WorkoutType
        }

        struct Week: Equatable, Sendable {
            let weekStart: Date
            /// The mean time of that week's runs: where the chart places the point, so it
            /// sits among the runs it summarises and never past today.
            let plotDate: Date
            /// The median easy pace that week, so one hilly or windy run doesn't drag it.
            let paceSecondsPerKm: Double
        }

        /// Every easy or long run with a pace, oldest first.
        let runs: [Run]
        /// One point per week that had one, oldest first.
        let weeks: [Week]
        /// Median easy pace in the later half of the runs minus the earlier half, in
        /// seconds per km: negative is faster. `nil` until there are at least
        /// `minimumRunsForChange` runs across at least `minimumWeeksForChange` weeks, since
        /// a change read off a couple of runs is noise.
        let changeSecondsPerKm: Double?

        static let minimumRunsForChange = 4
        static let minimumWeeksForChange = 3

        /// The latest week's typical easy pace, which the card leads with.
        var latestWeekPaceSecondsPerKm: Double? { weeks.last?.paceSecondsPerKm }
    }

    /// Workout types whose pace is comparable from one run to the next.
    static func countsAsEasyPace(_ type: WorkoutType) -> Bool {
        type == .easy || type == .longRun
    }

    static func easyPaceTrend(for runs: [RunWorkout]) -> EasyPaceTrend {
        let easy = runs.runsOnly
            .filter { run in
                let pace = run.averagePaceSecondsPerKm
                return countsAsEasyPace(run.workoutType) && pace > 0 && pace.isFinite
            }
            .sorted { $0.date < $1.date }
            .map { run in
                EasyPaceTrend.Run(
                    id: run.id,
                    date: run.date,
                    paceSecondsPerKm: run.averagePaceSecondsPerKm,
                    workoutType: run.workoutType
                )
            }

        let weeks = Dictionary(grouping: easy) { $0.date.startOfWeek }
            .compactMap { weekStart, weekRuns -> EasyPaceTrend.Week? in
                guard let pace = median(of: weekRuns.map(\.paceSecondsPerKm)) else { return nil }
                let meanTime = weekRuns.reduce(0) { $0 + $1.date.timeIntervalSinceReferenceDate }
                    / Double(weekRuns.count)
                return EasyPaceTrend.Week(
                    weekStart: weekStart,
                    plotDate: Date(timeIntervalSinceReferenceDate: meanTime),
                    paceSecondsPerKm: pace
                )
            }
            .sorted { $0.weekStart < $1.weekStart }

        var change: Double?
        if easy.count >= EasyPaceTrend.minimumRunsForChange,
           weeks.count >= EasyPaceTrend.minimumWeeksForChange {
            let half = easy.count / 2
            let earlier = easy.prefix(half).map(\.paceSecondsPerKm)
            let later = easy.suffix(half).map(\.paceSecondsPerKm)
            if let before = median(of: earlier), let after = median(of: later) {
                change = after - before
            }
        }
        return EasyPaceTrend(runs: easy, weeks: weeks, changeSecondsPerKm: change)
    }

    /// Middle value, or the mean of the middle two; `nil` for an empty sample.
    private static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: Period summary

    /// What the period summary card and the header show.
    ///
    /// Every average is optional so the view never has to guess whether a zero means
    /// "flat" or "nobody recorded this".
    struct Summary: Equatable, Sendable {
        let runCount: Int
        let totalDistanceMeters: Double
        /// Distance-weighted, in seconds per km. `nil` when the period covered no distance.
        let averagePaceSecondsPerKm: Double?
        /// Averaged over the runs that recorded heart rate, not over every run.
        let averageHeartRate: Double?
        /// Averaged over the runs that recorded a *positive* gain. A flat run and a run
        /// whose watch reported nothing are indistinguishable once stored, so both are
        /// excluded rather than dragging the average toward zero.
        let averageElevationGainMeters: Double?
        /// Averaged over the quality efforts that produced a VDOT sample.
        let averageVDOT: Double?
        /// The most recent VDOT sample, which the header shows as the current fitness mark.
        let latestVDOT: Double?

        static let empty = Summary(
            runCount: 0,
            totalDistanceMeters: 0,
            averagePaceSecondsPerKm: nil,
            averageHeartRate: nil,
            averageElevationGainMeters: nil,
            averageVDOT: nil,
            latestVDOT: nil
        )
    }

    /// Aggregates one period's runs.
    static func summary(for runs: [RunWorkout]) -> Summary {
        guard !runs.isEmpty else { return .empty }

        let pace = ProgressStatsService.distanceWeightedAveragePaceSecondsPerKm(for: runs)
        let samples = vdotSamples(for: runs)

        return Summary(
            runCount: runs.count,
            totalDistanceMeters: runs.reduce(0) { $0 + $1.distanceMeters },
            // The service returns 0 as its "no distance to divide by" sentinel; the card
            // needs that as an absent value, not as a 0:00/km pace.
            averagePaceSecondsPerKm: pace > 0 ? pace : nil,
            averageHeartRate: mean(of: runs.compactMap(\.averageHeartRate)),
            averageElevationGainMeters: mean(of: runs.compactMap(\.elevationGainMeters).filter { $0 > 0 }),
            averageVDOT: mean(of: samples.map(\.vdot)),
            latestVDOT: samples.last?.vdot
        )
    }

    /// Arithmetic mean, or `nil` for an empty sample.
    private static func mean(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
