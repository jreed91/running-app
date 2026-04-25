import Foundation

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
    /// Best VDOT from quality runs in the last 6 weeks. Nil when < 2 qualifying workouts exist.
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
    func snapshot(from history: [RunWorkout], profile: UserProfile) -> PerformanceSnapshot {
        let now = Date()

        // 1. Recent VDOT from best quality run
        let vdotCutoff = now.adding(weeks: -Self.lookbackWeeksVDOT)
        let qualityRuns = history.filter {
            $0.date >= vdotCutoff
                && $0.distanceMeters >= Self.qualityMinDistanceMeters
                && $0.workoutType.isQualitySession
        }
        let currentVDOT = vdotFromRuns(qualityRuns)

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

    // MARK: - Private helpers

    /// Returns the highest (best) VDOT from the supplied quality runs.
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
        return last.averagePaceSecondsPerKm / target
    }

    /// Derives VDOT from UserProfile's estimated 5K time.
    private func profileVDOT(from profile: UserProfile) -> Double? {
        guard let time = profile.currentEstimated5KTimeSeconds, time > 0 else { return nil }
        let v = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: time)
        return v.isFinite && v > 20 ? v : nil
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
