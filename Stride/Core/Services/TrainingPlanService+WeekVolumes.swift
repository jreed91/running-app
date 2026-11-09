import Foundation

// MARK: - Week volumes

/// Kept out of `TrainingPlanService.swift` so that type stays under SwiftLint's
/// `type_body_length` error.
extension TrainingPlanService {

    /// One week of a plan before its sessions exist: its phase, its trend volume, and how
    /// that volume splits between the runs.
    struct WeekVolume: Equatable, Sendable {
        let phase: TrainingPhase
        /// The week's volume on the progression, in km, after any recent-running ceiling.
        let trendKm: Double
        let shares: RunVolumeShares
        /// What the week's runs add up to, in km: what the plan shows as the week's target.
        var scheduledKm: Double { trendKm * shares.scheduledFraction }
    }

    /// Every week's volume, the one place both the plan and the setup screens' preview
    /// read it from, so "peak" on the last setup screen is the plan's peak.
    func weekVolumes(
        fitnessLevel: FitnessLevel,
        style: RaceType,
        numberOfWeeks: Int,
        runDays: Int,
        recentVolume: RecentRunningVolume?
    ) -> [WeekVolume] {
        let baseKm = fitnessLevel.startingWeeklyKm(for: style)
        let phases = phaseSchedule(totalWeeks: numberOfWeeks, raceType: style)
        return phases.enumerated().map { index, phase in
            let trendKm = weeklyKm(
                base: baseKm,
                weekIndex: index,
                totalWeeks: numberOfWeeks,
                phase: phase,
                raceType: style,
                ceilingKm: recentVolume?.ceilingKm(weekIndex: index)
            )
            // The long run's own ceiling from the runner's longest recent run, as a share
            // of this week. Infinite without recent running, so nothing changes then.
            let longCap = recentVolume.map { volume in
                trendKm > 0 ? volume.longRunCeilingKm(weekIndex: index) / trendKm : .infinity
            } ?? .infinity
            let shares = RunVolumeShares(
                runDays: runDays,
                qualitySlots: qualitySlotCount(runDays: runDays, phase: phase, raceType: style),
                longCap: longCap
            )
            return WeekVolume(phase: phase, trendKm: trendKm, shares: shares)
        }
    }

    /// The weeks a plan built from these choices would schedule, for the setup screens to
    /// show before the runner commits. Matches `generatePlan`/`generateRacePlan` week for
    /// week, bar the race itself replacing part of the last week.
    func previewWeeks(
        fitnessLevel: FitnessLevel,
        goalRace: RaceType,
        raceDistanceMeters: Double,
        numberOfWeeks: Int,
        runDays: Int,
        recentVolume: RecentRunningVolume?
    ) -> [WeekVolume] {
        weekVolumes(
            fitnessLevel: fitnessLevel,
            style: goalRace.trainingStyle(forDistanceMeters: raceDistanceMeters),
            numberOfWeeks: max(1, numberOfWeeks),
            runDays: min(max(runDays, 1), 7),
            recentVolume: recentVolume
        )
    }
}
