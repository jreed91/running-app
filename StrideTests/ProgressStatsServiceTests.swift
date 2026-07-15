import Foundation
import Testing
@testable import Stride

// MARK: - Progress stats (medal PRs, period averages) tests

@MainActor
struct ProgressStatsServiceTests {

    private let eligibleTypes: Set<WorkoutType> = [.easy, .tempo, .interval, .longRun, .race]

    // MARK: PR selection (H12)

    @Test("A short, slower run does not beat a genuine 5K PR")
    func shortSlowerRunDoesNotBeatGenuinePR() {
        // Doc counterexample: 4.50 km in 22:00 (4:53/km) vs. 5.00 km in 23:00 (4:36/km).
        // The shorter run must not win the 5K medal even though the old ±10% band included it.
        let shortJog = RunWorkout(distanceMeters: 4_500, durationSeconds: 22 * 60, workoutType: .easy)
        let genuinePR = RunWorkout(distanceMeters: 5_000, durationSeconds: 23 * 60, workoutType: .easy)

        let best = ProgressStatsService.personalRecordRun(
            in: [shortJog, genuinePR],
            targetMeters: 5_000,
            eligibleTypes: eligibleTypes
        )

        #expect(best === genuinePR)
    }

    @Test("Runs short of the target distance are excluded even without a faster alternative")
    func shortRunAloneIsNotEligible() {
        let shortJog = RunWorkout(distanceMeters: 4_500, durationSeconds: 22 * 60, workoutType: .easy)

        let best = ProgressStatsService.personalRecordRun(
            in: [shortJog],
            targetMeters: 5_000,
            eligibleTypes: eligibleTypes
        )

        #expect(best == nil)
    }

    @Test("A run right at the target distance is chosen by raw time")
    func exactDistanceRunUsesRawTime() {
        let slower = RunWorkout(distanceMeters: 5_000, durationSeconds: 23 * 60, workoutType: .easy)
        let faster = RunWorkout(distanceMeters: 5_000, durationSeconds: 21 * 60, workoutType: .easy)

        let best = ProgressStatsService.personalRecordRun(
            in: [slower, faster],
            targetMeters: 5_000,
            eligibleTypes: eligibleTypes
        )

        #expect(best === faster)
    }

    @Test("A longer run can still set the PR when its Riegel-normalized pace is faster")
    func longerRunCanWinOnNormalizedPace() {
        // 10K at a genuinely faster equivalent effort should still beat a merely-adequate 5K.
        let tenK = RunWorkout(distanceMeters: 10_000, durationSeconds: 40 * 60, workoutType: .easy)
        let fiveK = RunWorkout(distanceMeters: 5_000, durationSeconds: 23 * 60, workoutType: .easy)

        let best = ProgressStatsService.personalRecordRun(
            in: [tenK, fiveK],
            targetMeters: 5_000,
            eligibleTypes: eligibleTypes
        )

        #expect(best === tenK)
    }

    @Test("Ineligible workout types are excluded from PR consideration")
    func ineligibleWorkoutTypeExcluded() {
        let strengthDay = RunWorkout(distanceMeters: 5_000, durationSeconds: 20 * 60, workoutType: .crossTraining)

        let best = ProgressStatsService.personalRecordRun(
            in: [strengthDay],
            targetMeters: 5_000,
            eligibleTypes: eligibleTypes
        )

        #expect(best == nil)
    }

    @Test("No candidates returns nil")
    func noCandidatesReturnsNil() {
        let best = ProgressStatsService.personalRecordRun(
            in: [],
            targetMeters: 5_000,
            eligibleTypes: eligibleTypes
        )
        #expect(best == nil)
    }

    // MARK: Distance-weighted average pace (M33)

    @Test("Period average pace is distance-weighted, not an unweighted mean of run paces")
    func averagePaceIsDistanceWeighted() {
        // Doc example: one long fast run (19 km @ 5:00/km) + one short slow jog (1 km @ 8:00/km).
        // Unweighted mean of paces = (300 + 480) / 2 = 390 s/km = 6:30/km (the bug).
        // Distance-weighted = (5700 + 480) / 20 = 309 s/km = 5:09/km (the fix).
        let longFastRun = RunWorkout(distanceMeters: 19_000, durationSeconds: 5_700, workoutType: .longRun)
        let shortSlowJog = RunWorkout(distanceMeters: 1_000, durationSeconds: 480, workoutType: .easy)

        let avgPace = ProgressStatsService.distanceWeightedAveragePaceSecondsPerKm(for: [longFastRun, shortSlowJog])

        #expect(abs(avgPace - 309) < 0.01)

        // The old, buggy unweighted mean would have produced 390 (6:30/km) — confirm we don't match it.
        let unweightedMean = [longFastRun, shortSlowJog]
            .map(\.averagePaceSecondsPerKm)
            .reduce(0, +) / 2
        #expect(abs(unweightedMean - 390) < 0.01)
        #expect(abs(avgPace - unweightedMean) > 1)
    }

    @Test("Distance-weighted average pace guards zero total distance")
    func averagePaceGuardsZeroDistance() {
        #expect(ProgressStatsService.distanceWeightedAveragePaceSecondsPerKm(for: []) == 0)

        let zeroDistanceRun = RunWorkout(distanceMeters: 0, durationSeconds: 0, workoutType: .easy)
        #expect(ProgressStatsService.distanceWeightedAveragePaceSecondsPerKm(for: [zeroDistanceRun]) == 0)
    }

    @Test("Distance-weighted average pace matches a single run's own pace")
    func averagePaceSingleRunMatchesItsOwnPace() {
        let run = RunWorkout(distanceMeters: 10_000, durationSeconds: 3_000, workoutType: .easy)
        let avgPace = ProgressStatsService.distanceWeightedAveragePaceSecondsPerKm(for: [run])
        #expect(abs(avgPace - run.averagePaceSecondsPerKm) < 0.01)
    }
}
