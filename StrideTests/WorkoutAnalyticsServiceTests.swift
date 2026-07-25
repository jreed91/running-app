import Testing
import Foundation
@testable import Stride

/// Covers the training-math correctness fixes H2.1 (interval classification from
/// splits, not the whole-session average) and H2.3 (VDOT sampled only from race
/// efforts, never warm-up/recovery-inflated quality-session averages).
struct WorkoutAnalyticsServiceTests {

    private let service = WorkoutAnalyticsService()

    // Fixed reference date so lookback windows are deterministic.
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 1)) ?? .now
    private func daysAgo(_ n: Int) -> Date { now.addingTimeInterval(Double(-n) * 86_400) }

    private func makeProfile(time5KSeconds: Double = 22 * 60) -> UserProfile {
        UserProfile(
            name: "Test Runner",
            goalRace: .fiveK,
            goalFinishTime: 20 * 60,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate,
            currentEstimated5KTimeSeconds: time5KSeconds
        )
    }

    /// Builds a run with explicit per-km split paces. `averagePaceSecondsPerKm`
    /// is derived from `distanceMeters`/`durationSeconds` in the initializer.
    private func makeRun(
        type: WorkoutType,
        date: Date,
        distanceMeters: Double,
        durationSeconds: Double,
        splitPaces: [Double] = []
    ) -> RunWorkout {
        let run = RunWorkout(
            date: date,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            workoutType: type
        )
        if !splitPaces.isEmpty {
            run.splits = splitPaces.enumerated().map { idx, pace in
                Split(
                    kilometer: idx + 1,
                    paceSecondsPerKm: pace,
                    heartRate: nil,
                    elevationGainMeters: 0,
                    cumulativeDistanceMeters: Double(idx + 1) * 1_000
                )
            }
        }
        return run
    }

    // MARK: - H2.1 interval classification

    @Test("On-target interval reps do not classify as struggling")
    func onTargetIntervalsNotStruggling() {
        let profile = makeProfile()
        let target = PaceCalculatorService.trainingPaces(from5KTimeSeconds: 22 * 60).interval

        // 3 rep splits at target pace; 6 warm-up/recovery/cool-down splits far slower.
        // Whole-session average (~1.5x target) is what the old code used — it would
        // have read ~1.5 and forced .struggling.
        let splitPaces = [target, target, target] + Array(repeating: target * 1.7, count: 6)
        let avgPace = target * 1.5
        let run = makeRun(
            type: .interval,
            date: daysAgo(3),
            distanceMeters: 9_000,
            durationSeconds: avgPace * 9,
            splitPaces: splitPaces
        )

        let snap = service.snapshot(from: [run], profile: profile, now: now)

        #expect(snap.lastIntervalPaceRatio != nil)
        if let ratio = snap.lastIntervalPaceRatio {
            #expect(abs(ratio - 1.0) < 0.02, "effort ratio should reflect reps (~1.0), got \(ratio)")
        }
        #expect(snap.performanceTrend != .struggling)
    }

    @Test("Genuinely slow interval reps still classify as struggling")
    func slowIntervalsStillStruggling() {
        let profile = makeProfile()
        let target = PaceCalculatorService.trainingPaces(from5KTimeSeconds: 22 * 60).interval

        // Even the fastest reps are ~15% slower than target.
        let repPace = target * 1.15
        let splitPaces = [repPace, repPace, repPace] + Array(repeating: target * 1.9, count: 6)
        let run = makeRun(
            type: .interval,
            date: daysAgo(3),
            distanceMeters: 9_000,
            durationSeconds: target * 1.6 * 9,
            splitPaces: splitPaces
        )

        let snap = service.snapshot(from: [run], profile: profile, now: now)

        if let ratio = snap.lastIntervalPaceRatio {
            #expect(ratio > 1.07, "genuinely slow reps should exceed struggling threshold, got \(ratio)")
        }
        #expect(snap.performanceTrend == .struggling)
    }

    @Test("Interval without splits falls back to session average")
    func intervalWithoutSplitsUsesSessionAverage() {
        let profile = makeProfile()
        let target = PaceCalculatorService.trainingPaces(from5KTimeSeconds: 22 * 60).interval
        let run = makeRun(
            type: .interval,
            date: daysAgo(3),
            distanceMeters: 6_000,
            durationSeconds: target * 6 // session average == target
        )

        let snap = service.snapshot(from: [run], profile: profile, now: now)

        if let ratio = snap.lastIntervalPaceRatio {
            #expect(abs(ratio - 1.0) < 0.02)
        }
    }

    // MARK: - H2.3 VDOT from race efforts only

    @Test("VDOT comes from race efforts, not tempo/interval averages")
    func vdotIgnoresNonRaceQualitySessions() {
        let profile = makeProfile()
        // A fast tempo and a fast interval that WOULD yield a high VDOT if their
        // whole-session averages were treated as race efforts.
        let tempo = makeRun(type: .tempo, date: daysAgo(5), distanceMeters: 6_000, durationSeconds: 24 * 60)
        let interval = makeRun(type: .interval, date: daysAgo(10), distanceMeters: 8_000, durationSeconds: 34 * 60)

        let snap = service.snapshot(from: [tempo, interval], profile: profile, now: now)

        #expect(snap.currentVDOT == nil, "no race efforts → currentVDOT must be nil, not a biased quality-session value")
    }

    @Test("A race effort drives currentVDOT")
    func raceEffortDrivesVDOT() {
        let profile = makeProfile()
        let raceTime = 21 * 60.0
        let race = makeRun(type: .race, date: daysAgo(7), distanceMeters: 5_000, durationSeconds: raceTime)

        let snap = service.snapshot(from: [race], profile: profile, now: now)

        let expected = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: raceTime)
        #expect(snap.currentVDOT != nil)
        if let vdot = snap.currentVDOT {
            #expect(abs(vdot - expected) < 0.01)
        }
    }

    @Test("Race efforts outside the lookback window are excluded")
    func staleRaceExcludedFromVDOT() {
        let profile = makeProfile()
        // 7 weeks ago — beyond the 6-week VDOT lookback.
        let race = makeRun(type: .race, date: daysAgo(50), distanceMeters: 5_000, durationSeconds: 21 * 60)

        let snap = service.snapshot(from: [race], profile: profile, now: now)

        #expect(snap.currentVDOT == nil)
    }

    @Test("Tempo insights previous VDOT ignores non-race quality sessions")
    func tempoInsightsPreviousVDOTRaceOnly() {
        let profile = makeProfile()
        let priorTempo = makeRun(type: .tempo, date: daysAgo(10), distanceMeters: 6_000, durationSeconds: 25 * 60)
        let thisTempo = makeRun(type: .tempo, date: now, distanceMeters: 6_000, durationSeconds: 26 * 60)

        let insights = service.tempoInsights(for: thisTempo, history: [priorTempo], profile: profile)

        #expect(insights.previousVDOT == nil, "prior tempos are not race efforts and must not seed previousVDOT")
    }

    /// `RunSummaryView` passes a history already narrowed to tempo and race runs, so it can
    /// keep the all-time "previous best tempo" without fetching every run in the store (D6).
    /// This pins that equivalence: if `tempoInsights` ever starts consulting another type,
    /// this test fails rather than the screen quietly losing data.
    @Test("Tempo insights consult only tempo and race history")
    func tempoInsightsIgnoreOtherWorkoutTypes() {
        let profile = makeProfile()
        let thisTempo = makeRun(type: .tempo, date: now, distanceMeters: 6_000, durationSeconds: 26 * 60)
        let priorTempo = makeRun(type: .tempo, date: daysAgo(10), distanceMeters: 6_000, durationSeconds: 25 * 60)
        let priorRace = makeRun(type: .race, date: daysAgo(20), distanceMeters: 5_000, durationSeconds: 21 * 60)
        let noise = [
            makeRun(type: .easy, date: daysAgo(2), distanceMeters: 8_000, durationSeconds: 48 * 60),
            makeRun(type: .longRun, date: daysAgo(5), distanceMeters: 18_000, durationSeconds: 100 * 60),
            makeRun(type: .interval, date: daysAgo(7), distanceMeters: 7_000, durationSeconds: 32 * 60)
        ]

        let narrow = service.tempoInsights(
            for: thisTempo, history: [priorTempo, priorRace], profile: profile
        )
        let full = service.tempoInsights(
            for: thisTempo, history: [priorTempo, priorRace] + noise, profile: profile
        )

        #expect(narrow == full)
        #expect(narrow.previousBestTempoSecondsPerKm == priorTempo.averagePaceSecondsPerKm)
        #expect(narrow.recentTempoCount == 1)
        #expect(narrow.previousVDOT != nil)
    }
}
