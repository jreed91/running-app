import Foundation
import Testing
@testable import Stride

// MARK: - Watch run checkpoint tests
//
// After a crash the Watch gets the workout back from HealthKit, and its plan session and
// steps back from `WatchRunCheckpoint`. These pin that the steps come back where they were
// and that cues don't repeat the splits already run.

struct WatchRunCheckpointTests {

    /// 1 km warm-up, 2 × 400 m with 60 s jogs, 1 km cool-down.
    private var session: WatchRunSession {
        WatchRunSession(
            sessionID: UUID(),
            scheduledDate: Date(),
            title: "Interval",
            targetDistanceMeters: nil,
            targetPaceLowerSecondsPerKm: nil,
            targetPaceUpperSecondsPerKm: nil,
            structure: WorkoutStructure(
                warmup: WorkoutSegment(distanceMeters: 1_000, label: "Warm-up"),
                mainSets: [WorkoutSet(
                    repetitions: 2,
                    workSegment: WorkoutSegment(distanceMeters: 400, targetPaceSecondsPerKm: 240, label: "Rep"),
                    recoverySegment: WorkoutSegment(durationSeconds: 60, label: "Jog"),
                    label: "Reps"
                )],
                cooldown: WorkoutSegment(distanceMeters: 1_000, label: "Cool-down"),
                totalEstimatedDistanceMeters: 2_800,
                totalEstimatedDurationSeconds: 1_100
            ),
            usesRunWalkCues: false,
            maxHeartRateBPM: nil,
            usesMetricUnits: true,
            speaksSplits: true,
            speaksSteps: true
        )
    }

    private func at(_ meters: Double, _ seconds: Double) -> WatchRunMetrics {
        WatchRunMetrics(elapsedSeconds: seconds, distanceMeters: meters)
    }

    @Test("Steps replayed from a checkpoint are where they were, with the same progress")
    func replaysSteps() throws {
        let session = session
        var run = try #require(WatchGuidedRun(session: session))
        _ = run.update(with: at(1_000, 300)) // into rep 1
        _ = run.update(with: at(1_400, 390)) // into the jog
        let checkpoint = WatchRunCheckpoint(runSession: session, usesMetricUnits: true, stepStarts: run.stepStarts)

        let restored = try #require(checkpoint.guided())

        #expect(restored.stepPosition == run.stepPosition)
        #expect(restored.currentStep.kind == .recovery)
        #expect(restored.remainingText(with: at(1_450, 420), metric: true)
            == run.remainingText(with: at(1_450, 420), metric: true))
    }

    @Test("A checkpoint survives a save and load, and clear removes it")
    func savesAndLoads() throws {
        let defaults = try #require(UserDefaults(suiteName: "WatchRunCheckpointTests"))
        defer { defaults.removePersistentDomain(forName: "WatchRunCheckpointTests") }
        let checkpoint = WatchRunCheckpoint(
            runSession: session,
            usesMetricUnits: false,
            stepStarts: [WatchGuidedRun.StepStart(distanceMeters: 1_000, elapsedSeconds: 300)]
        )

        checkpoint.save(to: defaults)
        #expect(WatchRunCheckpoint.load(from: defaults) == checkpoint)

        WatchRunCheckpoint.clear(in: defaults)
        #expect(WatchRunCheckpoint.load(from: defaults) == nil)
    }

    @Test("A free run's checkpoint has no steps")
    func freeRun() {
        let checkpoint = WatchRunCheckpoint(runSession: nil, usesMetricUnits: true, stepStarts: [])
        #expect(checkpoint.guided() == nil)
    }

    @Test("Cues resumed mid-run don't repeat the splits already run")
    func cuesResume() {
        var cues = WatchRunCues(unit: .metric, speaksSplits: true, speaksSteps: false)
        cues.resume(at: at(3_400, 1_020))
        let same = cues.phrases(for: at(3_500, 1_050), guidedBefore: nil, guidedAfter: nil)
        let next = cues.phrases(for: at(4_001, 1_320), guidedBefore: nil, guidedAfter: nil)
        #expect(same.isEmpty)
        #expect(next == [SplitAnnouncement.phrase(splitNumber: 4, paceSecondsPerKm: 300, unit: .metric)])
    }

    @Test("The battery warning shows at 15% and below, and never when the level is unknown")
    func battery() {
        #expect(WatchBattery.warningPercent(level: 0.5) == nil)
        #expect(WatchBattery.warningPercent(level: 0.15) == 15)
        #expect(WatchBattery.warningPercent(level: 0.08) == 8)
        #expect(WatchBattery.warningPercent(level: -1) == nil)
    }
}
