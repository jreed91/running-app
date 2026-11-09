import Foundation
import HealthKit

extension HealthKitRepositoryProtocol {
    /// The runner's recent running from Health, for sizing a new plan's first weeks.
    ///
    /// Reads Health directly rather than the runs Stride has imported, because a plan is
    /// often built in onboarding, before the first import has run. Any failure, or no Health
    /// at all, is `nil`: the plan is then built from the fitness level alone, as before.
    func recentRunningVolume(now: Date = Date()) async -> RecentRunningVolume? {
        guard isAvailable else { return nil }
        let start = now.addingTimeInterval(-Double(RecentRunningVolume.lookbackWeeks) * 7 * 86_400)
        do {
            let workouts = try await fetchWorkouts(from: start, to: now)
            let distanceType = HKQuantityType(.distanceWalkingRunning)
            let runs = workouts.map { workout in
                RecentRunningVolume.Run(
                    date: workout.startDate,
                    meters: workout.statistics(for: distanceType)?.sumQuantity()?.doubleValue(for: .meter()) ?? 0
                )
            }
            let volume = RecentRunningVolume(runs: runs, now: now)
            AppLogger.log(
                "Recent running for plan sizing: \(runs.count) run(s), "
                    + (volume.map { String(format: "%.1f km/week over 4 weeks", $0.averageWeeklyKm) } ?? "none"),
                label: "Plan",
                level: .debug
            )
            return volume
        } catch {
            AppLogger.log("Couldn't read recent runs for plan sizing: \(error)", label: "Plan", level: .error)
            return nil
        }
    }
}
