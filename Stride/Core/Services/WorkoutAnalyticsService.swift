import Foundation

// MARK: - TempoInsights

/// Pace insights derived from a single completed tempo run.
struct TempoInsights: Sendable, Equatable {
    /// Actual average pace achieved during the tempo run (sec/km).
    let achievedPaceSecondsPerKm: Double
    /// VDOT-derived threshold pace target based on prior quality runs (sec/km). Nil when history is insufficient.
    let targetThresholdSecondsPerKm: Double?
    /// Best average tempo pace from prior tempo runs (sec/km). Nil when no prior tempos exist.
    let previousBestTempoSecondsPerKm: Double?
    /// VDOT implied by this run's distance and time. Nil for degenerate inputs.
    let derivedVDOT: Double?
    /// Best VDOT from race efforts in the 6 weeks prior to this run (excluding this run). Nil when no race efforts exist.
    let previousVDOT: Double?
    /// Standard deviation of per-km split paces (sec). Lower = more consistent effort. Nil when < 2 splits.
    let splitConsistencySeconds: Double?
    /// Number of tempo workouts in the 8-week window prior to this run.
    let recentTempoCount: Int
}

// MARK: - PerformanceTrend

enum PerformanceTrend: Sendable {
    /// Runner consistently hits or beats targets (≥7% faster, or improving OLS slope).
    case improving
    /// Runner is within ±7% of targets.
    case onTrack
    /// Runner is struggling (≥7% slower, HR spiking, or worsening trend).
    case struggling
}

// MARK: - PerformanceSnapshot

/// A point-in-time summary of the runner's recent performance, derived from
/// completed ``RunWorkout`` history.
struct PerformanceSnapshot: Sendable {
    /// Best VDOT from race efforts in the last 6 weeks. Nil when no race efforts exist.
    var currentVDOT: Double?

    /// OLS slope of pace vs time over the last 8 weeks (seconds/km per day).
    /// Negative = improving (pace decreasing). Nil when < 4 data points.
    var paceTrendPerDay: Double?

    /// Average pace across completed interval/tempo workouts in the last 4 weeks.
    var recentQualityPaceSecondsPerKm: Double?

    /// Average weekly distance over the last 4 weeks (metres).
    var averageWeeklyDistanceMeters: Double

    /// HR fatigue indicator: ratio of late-split HR to early-split HR averaged across the
    /// most recent 3 interval sessions. Values > 1.15 suggest poor recovery between intervals.
    var intervalFatigueRatio: Double?

    /// Ratio of actual pace to target pace on the most recently completed interval workout.
    /// < 1.0 means the runner ran faster than target.
    var lastIntervalPaceRatio: Double?

    /// Overall performance classification.
    var performanceTrend: PerformanceTrend
}

// MARK: - WorkoutAnalyticsService

/// Pure, stateless service that analyses ``RunWorkout`` history to produce a
/// ``PerformanceSnapshot`` used by ``TrainingPlanService`` to adapt workouts.
struct WorkoutAnalyticsService: Sendable {

    // MARK: - Constants

    private static let qualityMinDistanceMeters: Double = 1_500
    private static let lookbackWeeksVDOT: Int = 6
    private static let lookbackWeeksTrend: Int = 8
    private static let lookbackWeeksQuality: Int = 4

    // MARK: - Public API

    /// Analyses `history` and produces a ``PerformanceSnapshot``.
    /// `now` is injectable so callers (and tests) can pin the reference date.
    func snapshot(from history: [RunWorkout], profile: UserProfile, now: Date = Date()) -> PerformanceSnapshot {
        // Every figure below is a statement about running fitness — a pace trend, a
        // weekly volume, a VDOT — so imported walks are dropped once here rather than
        // remembered by each of the six passes (N38). The pace trend is the sharpest
        // case: a couple of walks in an eight-week window read as a runner losing form.
        let history = history.runsOnly

        // 1. Recent VDOT from best race effort. Only genuine race efforts are used:
        // tempo/interval session averages fold in warm-up, recovery jogs, and
        // cool-down, so treating them as race efforts biases VDOT (and every
        // derived pace) low. Non-racers fall back to the profile estimate below.
        let vdotCutoff = now.adding(weeks: -Self.lookbackWeeksVDOT)
        let raceRuns = history.filter {
            $0.date >= vdotCutoff
                && $0.distanceMeters >= Self.qualityMinDistanceMeters
                && $0.workoutType == .race
        }
        let currentVDOT = vdotFromRuns(raceRuns)

        // 2. OLS pace trend across all runs last 8 weeks
        let trendCutoff = now.adding(weeks: -Self.lookbackWeeksTrend)
        let trendRuns = history.filter { $0.date >= trendCutoff && $0.distanceMeters >= 1_000 }
        let paceTrend = paceTrendSlope(from: trendRuns)

        // 3. Average quality pace last 4 weeks
        let qualityCutoff = now.adding(weeks: -Self.lookbackWeeksQuality)
        let recentQuality = history.filter {
            $0.date >= qualityCutoff && $0.workoutType.isQualitySession
        }
        let recentQualityPace: Double? = recentQuality.isEmpty
            ? nil
            : recentQuality.reduce(0) { $0 + $1.averagePaceSecondsPerKm } / Double(recentQuality.count)

        // 4. Average weekly mileage last 4 weeks
        let avgWeeklyDistance = averageWeeklyDistance(from: history, weeks: 4, referenceDate: now)

        // 5. Interval fatigue (HR-based)
        let recentIntervals = history
            .filter { $0.date >= qualityCutoff && $0.workoutType == .interval && !$0.splits.isEmpty }
            .sorted { $0.date > $1.date }
        let fatigueRatio = intervalFatigueRatio(from: Array(recentIntervals.prefix(3)))

        // 6. Last interval pace ratio vs VDOT-derived target
        let effectiveVDOT = currentVDOT ?? profileVDOT(from: profile)
        let lastIntervalRatio = lastIntervalPaceRatio(
            from: history,
            targetIntervalPace: effectiveVDOT.map { PaceCalculatorService.trainingPaces(forVDOT: $0).interval }
        )

        // 7. Classify overall trend
        let trend = classify(
            paceRatio: lastIntervalRatio,
            fatigueRatio: fatigueRatio,
            paceTrendSlope: paceTrend
        )

        return PerformanceSnapshot(
            currentVDOT: currentVDOT,
            paceTrendPerDay: paceTrend,
            recentQualityPaceSecondsPerKm: recentQualityPace,
            averageWeeklyDistanceMeters: avgWeeklyDistance,
            intervalFatigueRatio: fatigueRatio,
            lastIntervalPaceRatio: lastIntervalRatio,
            performanceTrend: trend
        )
    }

    // MARK: - Tempo Insights

    /// Produces ``TempoInsights`` for a completed tempo run given workout history and runner profile.
    /// `history` should include all runs **excluding** the workout being analysed so that
    /// comparisons reflect the state before this session.
    ///
    /// Only `.tempo` and `.race` runs are consulted — an all-time best tempo pace, the count
    /// of tempos in the last eight weeks, and race efforts inside six weeks — so a caller may
    /// pass a history already narrowed to those two types. `RunSummaryView` does exactly
    /// that, which is how it keeps the all-time comparison without fetching every run in the
    /// store (D6); `WorkoutAnalyticsServiceTests` pins the equivalence.
    func tempoInsights(for workout: RunWorkout, history: [RunWorkout], profile: UserProfile) -> TempoInsights {
        let now = workout.date

        // Previous best tempo pace (excluding this run)
        let previousTempos = history.filter { $0.workoutType == .tempo && $0.distanceMeters >= Self.qualityMinDistanceMeters }
        let previousBest = previousTempos.map(\.averagePaceSecondsPerKm).min()

        // Recent tempo count (8-week lookback)
        let eightWeekCutoff = now.adding(weeks: -8)
        let recentTempoCount = previousTempos.filter { $0.date >= eightWeekCutoff }.count

        // VDOT from this run
        let derivedVDOT: Double? = {
            guard workout.durationSeconds > 0, workout.distanceMeters >= Self.qualityMinDistanceMeters else { return nil }
            let v = PaceCalculatorService.vdot(distanceMeters: workout.distanceMeters, timeSeconds: workout.durationSeconds)
            return v.isFinite && v > 20 ? v : nil
        }()

        // Previous VDOT from race efforts in the 6 weeks before this run. Only
        // race efforts qualify — a tempo/interval average understates true VDOT
        // because it includes warm-up/recovery/cool-down (see `snapshot`).
        let vdotCutoff = now.adding(weeks: -Self.lookbackWeeksVDOT)
        let priorRaces = history.filter {
            $0.date >= vdotCutoff
                && $0.distanceMeters >= Self.qualityMinDistanceMeters
                && $0.workoutType == .race
        }
        let previousVDOT = vdotFromRuns(priorRaces)

        // Target threshold pace: derived from best prior VDOT (or profile VDOT if no history)
        let baseVDOT = previousVDOT ?? profileVDOT(from: profile)
        let targetThreshold = baseVDOT.map { PaceCalculatorService.trainingPaces(forVDOT: $0).threshold }

        // Split consistency: std dev of split paces
        let splitPaces = workout.splits.map(\.paceSecondsPerKm)
        let splitConsistency: Double? = {
            guard splitPaces.count >= 2 else { return nil }
            let mean = splitPaces.reduce(0, +) / Double(splitPaces.count)
            let variance = splitPaces.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(splitPaces.count)
            return sqrt(variance)
        }()

        return TempoInsights(
            achievedPaceSecondsPerKm: workout.averagePaceSecondsPerKm,
            targetThresholdSecondsPerKm: targetThreshold,
            previousBestTempoSecondsPerKm: previousBest,
            derivedVDOT: derivedVDOT,
            previousVDOT: previousVDOT,
            splitConsistencySeconds: splitConsistency,
            recentTempoCount: recentTempoCount
        )
    }

    // MARK: - Private helpers

    /// Returns the highest (best) VDOT from the supplied race-effort runs.
    private func vdotFromRuns(_ runs: [RunWorkout]) -> Double? {
        let candidates = runs.compactMap { run -> Double? in
            guard run.durationSeconds > 0 else { return nil }
            let v = PaceCalculatorService.vdot(
                distanceMeters: run.distanceMeters,
                timeSeconds: run.durationSeconds
            )
            return v.isFinite && v > 20 ? v : nil
        }
        return candidates.max()
    }

    /// OLS slope of (date-in-days, pace) for the supplied runs.
    /// Returns nil if fewer than 4 data points.
    private func paceTrendSlope(from runs: [RunWorkout]) -> Double? {
        guard runs.count >= 4 else { return nil }
        let points = runs.map { run in
            (x: run.date.timeIntervalSinceReferenceDate / 86_400,
             y: run.averagePaceSecondsPerKm)
        }
        return PaceCalculatorService.linearRegressionSlope(points)
    }

    /// Average weekly distance in metres over `weeks` weeks ending at `referenceDate`.
    private func averageWeeklyDistance(
        from history: [RunWorkout],
        weeks: Int,
        referenceDate: Date
    ) -> Double {
        let cutoff = referenceDate.adding(weeks: -weeks)
        let total = history
            .filter { $0.date >= cutoff }
            .reduce(0) { $0 + $1.distanceMeters }
        return total / Double(max(weeks, 1))
    }

    /// HR fatigue: ratio of late-quarter HR to early-quarter HR, averaged across sessions.
    private func intervalFatigueRatio(from sessions: [RunWorkout]) -> Double? {
        guard !sessions.isEmpty else { return nil }
        var ratios: [Double] = []
        for session in sessions {
            let splits = session.splits
            guard splits.count >= 4 else { continue }
            let quarter = max(1, splits.count / 4)
            let earlyHR = splits.prefix(quarter).compactMap(\.heartRate)
            let lateHR  = splits.suffix(quarter).compactMap(\.heartRate)
            guard !earlyHR.isEmpty, !lateHR.isEmpty else { continue }
            let early = earlyHR.reduce(0, +) / Double(earlyHR.count)
            let late  = lateHR.reduce(0, +)  / Double(lateHR.count)
            guard early > 0 else { continue }
            ratios.append(late / early)
        }
        return ratios.isEmpty ? nil : ratios.reduce(0, +) / Double(ratios.count)
    }

    /// Ratio of actual/target pace for the most recent interval workout.
    /// Uses the work-effort pace (see ``intervalEffortPace(for:)``) rather than
    /// the whole-session average, which folds in warm-up, recovery jogs, and
    /// cool-down and would otherwise read ~30% slow — permanently classifying
    /// even on-target interval sessions as `.struggling`.
    private func lastIntervalPaceRatio(
        from history: [RunWorkout],
        targetIntervalPace: Double?
    ) -> Double? {
        guard let target = targetIntervalPace, target > 0 else { return nil }
        guard let last = history
            .filter({ $0.workoutType == .interval })
            .sorted(by: { $0.date > $1.date })
            .first
        else { return nil }
        return intervalEffortPace(for: last) / target
    }

    /// Estimates the pace of the *work* portion of an interval session from its
    /// per-km splits, so classification reflects the reps rather than the
    /// warm-up/recovery/cool-down that dominate the whole-session average.
    /// Uses the fastest third of splits as a proxy for the rep efforts.
    /// Falls back to the session average when splits are unavailable (< 3).
    private func intervalEffortPace(for workout: RunWorkout) -> Double {
        let paces = workout.splits.map(\.paceSecondsPerKm).filter { $0 > 0 }
        guard paces.count >= 3 else { return workout.averagePaceSecondsPerKm }
        let workCount = max(1, paces.count / 3)
        let fastest = paces.sorted().prefix(workCount)
        return fastest.reduce(0, +) / Double(fastest.count)
    }

    /// Derives VDOT from UserProfile's estimated 5K time.
    private func profileVDOT(from profile: UserProfile) -> Double? {
        profile.baselineVDOT
    }

    /// Classifies the overall trend from available signals.
    private func classify(
        paceRatio: Double?,
        fatigueRatio: Double?,
        paceTrendSlope: Double?
    ) -> PerformanceTrend {
        // HR fatigue is the strongest signal — override everything else
        if let fatigue = fatigueRatio, fatigue > 1.15 { return .struggling }

        if let ratio = paceRatio {
            if ratio < 0.93 { return .improving }  // ≥7% faster than target
            if ratio > 1.07 { return .struggling } // ≥7% slower than target
        }

        // OLS pace slope as tiebreaker (sec/km per day; negative = improving)
        if let slope = paceTrendSlope {
            if slope < -1.0 { return .improving }
            if slope >  1.5 { return .struggling }
        }

        return .onTrack
    }
}
