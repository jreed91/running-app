import Foundation

// MARK: - StrengthPeriodStats

/// What the Progress tab says about strength over the period the range picker chose:
/// how often, how much, and how the main lifts moved.
///
/// Pure over ``StrengthSessionLog`` values, like ``ProgressPeriodStats`` is over runs.
struct StrengthPeriodStats: Equatable, Sendable {

    /// One lift's movement over the period, from its first loaded session in it to its
    /// latest.
    struct LiftTrend: Equatable, Sendable {
        let exerciseName: String
        /// Sessions in the period with a loaded set of this lift.
        let sessions: Int
        let latestWeightKilograms: Double
        /// Reps of the best set at the latest top load.
        let latestReps: Int
        /// Change in the Epley estimate from the first session to the latest, as a
        /// fraction (0.08 = 8% stronger). Nil with one session, or when either end had
        /// no set the estimate is fair for (over twelve reps).
        let change: Double?
    }

    let sessions: Int
    /// Sessions per week across the period.
    let sessionsPerWeek: Double
    /// Sets done, skipped ones left out.
    let workingSets: Int
    /// The lifts done with a load most often, at most ``maxLifts``, most sessions first.
    let lifts: [LiftTrend]

    static let maxLifts = 3

    /// The stats for sessions dated within `days` of `now`.
    static func make(
        from sessions: [StrengthSessionLog],
        withinDays days: Int,
        now: Date = Date()
    ) -> StrengthPeriodStats {
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        let inPeriod = sessions
            .filter { $0.date >= start && $0.date <= now }
            .sorted { $0.date < $1.date }

        let working = inPeriod.flatMap { $0.sets.filter { !$0.skipped } }

        // Each lift's loaded sessions, oldest first, keyed by the name as logged.
        var byLift: [String: [ExercisePerformance]] = [:]
        for session in inPeriod {
            let loaded = Dictionary(grouping: session.sets.filter { !$0.skipped && ($0.weightKilograms ?? 0) > 0 },
                                    by: \.exerciseName)
            for (name, sets) in loaded {
                byLift[name, default: []].append(ExercisePerformance(date: session.date, sets: sets))
            }
        }

        let lifts = byLift.compactMap { name, performances -> LiftTrend? in
            guard let latest = performances.last, let top = latest.topWeightKilograms else { return nil }
            let first = performances.first
            var change: Double?
            if performances.count > 1,
               let from = first?.estimatedOneRepMaxKilograms,
               let to = latest.estimatedOneRepMaxKilograms,
               from > 0 {
                change = to / from - 1
            }
            return LiftTrend(
                exerciseName: name,
                sessions: performances.count,
                latestWeightKilograms: top,
                latestReps: latest.topSets.map(\.reps).max() ?? 0,
                change: change
            )
        }
        .sorted { lhs, rhs in
            if lhs.sessions != rhs.sessions { return lhs.sessions > rhs.sessions }
            return lhs.exerciseName < rhs.exerciseName
        }

        let weeks = max(1, Double(days) / 7)
        return StrengthPeriodStats(
            sessions: inPeriod.count,
            sessionsPerWeek: Double(inPeriod.count) / weeks,
            workingSets: working.count,
            lifts: Array(lifts.prefix(maxLifts))
        )
    }
}
