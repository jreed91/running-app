import Foundation

struct AICoachInsight: Sendable {
    let headline: String
    let summary: String
    let focusAreas: [String]
    let nextWorkoutSuggestion: String
    let apiReady: Bool
}

/// Lightweight coaching layer that turns workout data into user-facing feedback.
///
/// This service intentionally supports two modes:
/// 1) Local-only heuristics (works without a key and keeps all data on-device)
/// 2) API-ready context assembly (when the runner opts in with their own key)
///
/// The external LLM call is left to a future network client so this service stays pure,
/// deterministic, and easy to test.
struct AICoachService: Sendable {

    func evaluate(
        workout: RunWorkout,
        recentHistory: [RunWorkout],
        profile: UserProfile?,
        apiKey: String
    ) -> AICoachInsight {
        let drift = paceDriftPercent(for: workout)
        let hrDrift = heartRateDrift(for: workout)
        let qualityRuns = recentHistory.filter { $0.workoutType.isQualitySession }
        let averageRecentPace = qualityRuns.isEmpty
            ? nil
            : qualityRuns.reduce(0) { $0 + $1.averagePaceSecondsPerKm } / Double(qualityRuns.count)

        var focus: [String] = []
        var summaryBits: [String] = []

        if let drift {
            if drift <= 3 {
                summaryBits.append("Great pacing control across the run.")
            } else if drift <= 7 {
                focus.append("Start 3–5 sec/km easier for the first 2 splits.")
                summaryBits.append("Moderate pace fade late in the workout.")
            } else {
                focus.append("Pace conservatively early and protect form in final third.")
                summaryBits.append("Large late-run fade suggests pacing or endurance mismatch.")
            }
        }

        if let hrDrift, hrDrift > 8 {
            focus.append("Add easy aerobic volume or extend recoveries between reps.")
            summaryBits.append("Heart-rate drift was elevated, indicating accumulating fatigue.")
        }

        if let averageRecentPace {
            let delta = workout.averagePaceSecondsPerKm - averageRecentPace
            if delta < -8 {
                summaryBits.append("This run was faster than your recent quality baseline.")
            } else if delta > 8 {
                focus.append("Prioritize recovery before the next quality day.")
                summaryBits.append("This run was slower than your recent quality baseline.")
            }
        }

        if focus.isEmpty {
            focus.append("Keep weekly consistency: 1 long run, 1 quality run, remaining easy.")
        }

        let raceContext = profile.map { "Goal: \($0.goalRace.displayName)." } ?? ""
        let apiReady = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let headline = apiReady ? "AI Coach Ready" : "On-device Coaching"

        let nextWorkout: String
        switch workout.workoutType {
        case .interval, .tempo:
            nextWorkout = "Next session should be easy (30–50 min) with low aerobic effort."
        case .longRun:
            nextWorkout = "Plan a short recovery run or rest day before quality intensity."
        default:
            nextWorkout = "Progress with one controlled quality session in 48–72 hours."
        }

        let summaryPrefix = apiReady
            ? "Using your key, Stride can enrich this with deeper AI analysis."
            : "Add an AI key in Settings to unlock deeper personalized explanations."

        let summary = ([summaryPrefix, raceContext] + summaryBits)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return AICoachInsight(
            headline: headline,
            summary: summary,
            focusAreas: Array(focus.prefix(3)),
            nextWorkoutSuggestion: nextWorkout,
            apiReady: apiReady
        )
    }

    private func paceDriftPercent(for workout: RunWorkout) -> Double? {
        guard workout.splits.count >= 4 else { return nil }
        let quarter = max(1, workout.splits.count / 4)
        let first = workout.splits.prefix(quarter).reduce(0) { $0 + $1.paceSecondsPerKm } / Double(quarter)
        let last = workout.splits.suffix(quarter).reduce(0) { $0 + $1.paceSecondsPerKm } / Double(quarter)
        guard first > 0 else { return nil }
        return max(0, ((last - first) / first) * 100)
    }

    private func heartRateDrift(for workout: RunWorkout) -> Double? {
        let hrs = workout.splits.compactMap(\.heartRate)
        guard hrs.count >= 4 else { return nil }
        let quarter = max(1, hrs.count / 4)
        let first = hrs.prefix(quarter).reduce(0, +) / Double(quarter)
        let last = hrs.suffix(quarter).reduce(0, +) / Double(quarter)
        guard first > 0 else { return nil }
        return ((last - first) / first) * 100
    }
}
