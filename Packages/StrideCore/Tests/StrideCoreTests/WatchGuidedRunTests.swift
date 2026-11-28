import Foundation
import Testing
@testable import StrideCore

// MARK: - Watch guided run tests
//
// The Watch steps a plan session through `WatchGuidedRun`, over the phone's own
// `GuidedWorkoutState`. The watch target has no test bundle, so its stepping, text and
// pace check are pinned here.

struct WatchGuidedRunTests {

    /// 1 km warm-up, 3 × 400 m at 4:00/km with 90 s jogs, 1 km cool-down.
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
                    repetitions: 3,
                    workSegment: WorkoutSegment(distanceMeters: 400, targetPaceSecondsPerKm: 240, label: "Rep"),
                    recoverySegment: WorkoutSegment(durationSeconds: 90, label: "Jog"),
                    label: "Reps"
                )],
                cooldown: WorkoutSegment(distanceMeters: 1_000, label: "Cool-down"),
                totalEstimatedDistanceMeters: 3_600,
                totalEstimatedDurationSeconds: 1_500
            ),
            usesRunWalkCues: false,
            maxHeartRateBPM: nil,
            usesMetricUnits: true
        )
    }

    private func at(_ meters: Double, _ seconds: Double, speed: Double? = nil) -> WatchRunMetrics {
        WatchRunMetrics(elapsedSeconds: seconds, distanceMeters: meters, currentSpeedMetersPerSecond: speed)
    }

    // `#expect` can't call a mutating method on the value it checks, so each step is
    // taken first and only its result is checked.

    @Test("A session with steps becomes a guided run; an easy run does not")
    func onlySessionsWithSteps() {
        #expect(WatchGuidedRun(session: session) != nil)
        var easy = session
        easy.structure = nil
        #expect(WatchGuidedRun(session: easy) == nil)
    }

    @Test("Steps move on when their distance or time is reached")
    func autoAdvance() throws {
        var run = try #require(WatchGuidedRun(session: session))
        let warmup = run.update(with: at(990, 300))
        #expect(warmup == 0)
        #expect(run.currentStep.kind == .warmup)

        let intoRep = run.update(with: at(1_000, 302))
        #expect(intoRep == 1)
        #expect(run.currentStep.kind == .work)
        #expect(run.stepTitle == "Rep 1/3")

        let intoJog = run.update(with: at(1_400, 400))
        #expect(intoJog == 1)
        #expect(run.currentStep.kind == .recovery)
        // A time step: 90 s from the moment it started.
        let early = run.update(with: at(1_600, 489))
        let onTime = run.update(with: at(1_610, 490))
        #expect(early == 0)
        #expect(onTime == 1)
        #expect(run.stepTitle == "Rep 2/3")
    }

    @Test("Next step skips ahead, and does nothing on the last step")
    func skip() throws {
        var run = try #require(WatchGuidedRun(session: session))
        let skipped = run.skip(with: at(200, 60))
        #expect(skipped)
        #expect(run.currentStep.kind == .work)
        while !run.isOnFinalStep { _ = run.skip(with: at(200, 60)) }
        #expect(run.currentStep.kind == .cooldown)
        let skippedLast = run.skip(with: at(200, 60))
        #expect(!skippedLast)
    }

    @Test("Remaining text is distance for a distance step and time for a time step")
    func remainingText() throws {
        var run = try #require(WatchGuidedRun(session: session))
        #expect(run.remainingText(with: at(580, 180), metric: true) == "0.42 km")
        _ = run.update(with: at(1_000, 300))
        _ = run.update(with: at(1_400, 400))
        #expect(run.remainingText(with: at(1_450, 430), metric: true) == "1:00")
        // Warm-up, rep, jog, rep, jog, rep, cool-down: no jog after the last rep.
        #expect(run.stepPosition == "3/7")
    }

    @Test("Pace is on target within 10 s/km either side")
    func paceStatus() throws {
        var run = try #require(WatchGuidedRun(session: session))
        // The warm-up has no target pace.
        #expect(run.paceStatus(with: at(500, 150, speed: 4)) == nil)
        _ = run.update(with: at(1_000, 300))
        #expect(run.paceStatus(with: at(1_100, 324, speed: 1_000 / 245)) == .onPace)
        #expect(run.paceStatus(with: at(1_100, 324, speed: 1_000 / 220)) == .tooFast)
        #expect(run.paceStatus(with: at(1_100, 324, speed: 1_000 / 265)) == .tooSlow)
        #expect(run.paceStatus(with: at(1_100, 324)) == nil)
    }
}
