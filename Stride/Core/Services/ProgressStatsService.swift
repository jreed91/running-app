import Foundation

// MARK: - ProgressStatsService

/// Pure, stateless helpers for Progress-tab statistics (medal PRs, period
/// averages) that previously lived inline in view bodies (`MedalsView`,
/// `ProgressView`) and therefore couldn't be unit tested. See AGENTS.md:
/// business logic belongs in services, not views.
struct ProgressStatsService: Sendable {

    /// Riegel exponent used to extrapolate a run's time to a different
    /// distance: `T2 = T1 * (D2/D1)^1.06`. See Pete Riegel, "Athletic Records
    /// and Human Endurance" (1977) — the standard formula for comparing
    /// performances across distances.
    static let riegelExponent = 1.06

    /// Minimum fraction of the target distance a run must cover to be
    /// considered for that distance's PR. A run short of the target — even by
    /// a fast pace — is not a genuine personal record for the target distance;
    /// this only allows for small GPS-measurement noise right at the target.
    static let minDistanceRatio = 0.98

    /// Finds the best personal-record run for `targetMeters` among `workouts`,
    /// restricted to `eligibleTypes`.
    ///
    /// Candidates must cover at least `minDistanceRatio` of the target
    /// distance; shorter runs are excluded outright regardless of pace, since
    /// they didn't actually complete the distance. Remaining candidates are
    /// ranked by their Riegel-extrapolated equivalent time at `targetMeters`
    /// (not raw duration and not raw pace), so a run that happens to be
    /// longer than the target isn't penalized just for taking more total time,
    /// and a run barely over the target isn't unfairly favored over one right
    /// at the target with a genuinely better pace.
    static func personalRecordRun(
        in workouts: [RunWorkout],
        targetMeters: Double,
        eligibleTypes: Set<WorkoutType>
    ) -> RunWorkout? {
        guard targetMeters > 0 else { return nil }
        let candidates = workouts.filter { workout in
            workout.durationSeconds > 0
                && workout.distanceMeters >= targetMeters * minDistanceRatio
                && eligibleTypes.contains(workout.workoutType)
        }
        return candidates.min { lhs, rhs in
            normalizedSeconds(for: lhs, targetMeters: targetMeters)
                < normalizedSeconds(for: rhs, targetMeters: targetMeters)
        }
    }

    /// Riegel-extrapolates `run`'s actual performance to the equivalent time
    /// at `targetMeters`.
    private static func normalizedSeconds(for run: RunWorkout, targetMeters: Double) -> Double {
        guard run.distanceMeters > 0 else { return .greatestFiniteMagnitude }
        return run.durationSeconds * pow(targetMeters / run.distanceMeters, riegelExponent)
    }

    /// Minimum distance (metres) a run must cover before its implied VDOT is a
    /// meaningful fitness sample. Very short runs produce noisy/extreme VDOT
    /// values, so they are excluded from the trend.
    static let minVO2SampleMeters = 400.0

    /// Estimates the VDOT (a VO₂max proxy) implied by a single run, or `nil`
    /// when the run should not contribute to the fitness trend.
    ///
    /// Only quality and race efforts (`WorkoutType.isQualitySession`) are
    /// sampled. An easy or long run is deliberately paced well below the
    /// runner's capability, so treating it as a maximal effort systematically
    /// drags the estimated-VO₂max trend downward — the same reason the
    /// analytics VDOT path restricts sampling to hard efforts. Runs shorter
    /// than `minVO2SampleMeters` or with no recorded duration are also excluded.
    static func estimatedVDOT(for run: RunWorkout) -> Double? {
        guard run.workoutType.isQualitySession,
              run.distanceMeters >= minVO2SampleMeters,
              run.durationSeconds > 0 else { return nil }
        let v = PaceCalculatorService.vdot(
            distanceMeters: run.distanceMeters,
            timeSeconds: run.durationSeconds
        )
        return v > 0 ? v : nil
    }

    /// Distance-weighted average pace (seconds per km) across `runs`: total
    /// duration over total distance, guarding the zero-distance case. This is
    /// the same Σduration/Σdistance pattern `PlanSummaryService` already uses,
    /// as opposed to an unweighted mean of each run's individual pace (which
    /// over-counts short runs and under-counts long ones).
    ///
    /// Returns 0 when there's no distance to divide by, matching callers'
    /// existing "no data" sentinel for this stat.
    static func distanceWeightedAveragePaceSecondsPerKm(for runs: [RunWorkout]) -> Double {
        let totalDistanceMeters = runs.reduce(0) { $0 + $1.distanceMeters }
        guard totalDistanceMeters > 0 else { return 0 }
        let totalDurationSeconds = runs.reduce(0) { $0 + $1.durationSeconds }
        return totalDurationSeconds / totalDistanceMeters * 1_000
    }
}
