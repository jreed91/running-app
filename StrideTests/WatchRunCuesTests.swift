import Foundation
import Testing
@testable import Stride

// MARK: - Watch run cues tests
//
// What the Watch says, and when. The words are the phone's own announcements, so these
// tests check timing and switches, comparing against those functions rather than
// copying their wording.

struct WatchRunCuesTests {

    private func at(_ meters: Double, _ seconds: Double) -> WatchRunMetrics {
        WatchRunMetrics(elapsedSeconds: seconds, distanceMeters: meters)
    }

    /// 1 km warm-up, 2 × 400 m with a 60 s jog, 1 km cool-down.
    private var guided: WatchGuidedRun {
        let structure = WorkoutStructure(
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
        )
        // swiftlint:disable:next force_unwrapping
        return WatchGuidedRun(state: GuidedWorkoutState(structure: structure)!)
    }

    @Test("A split is spoken once, as the kilometre is crossed, with that kilometre's pace")
    func splits() {
        var cues = WatchRunCues(unit: .metric, speaksSplits: true, speaksSteps: false)
        #expect(cues.phrases(for: at(990, 297), guidedBefore: nil, guidedAfter: nil).isEmpty)
        #expect(cues.phrases(for: at(1_005, 300), guidedBefore: nil, guidedAfter: nil)
            == [SplitAnnouncement.phrase(splitNumber: 1, paceSecondsPerKm: 300, unit: .metric)])
        #expect(cues.phrases(for: at(1_200, 360), guidedBefore: nil, guidedAfter: nil).isEmpty)
        #expect(cues.phrases(for: at(2_001, 570), guidedBefore: nil, guidedAfter: nil)
            == [SplitAnnouncement.phrase(splitNumber: 2, paceSecondsPerKm: 270, unit: .metric)])
    }

    @Test("Miles split every 1,609 m")
    func mileSplits() {
        var cues = WatchRunCues(unit: .imperial, speaksSplits: true, speaksSteps: false)
        #expect(cues.phrases(for: at(1_500, 450), guidedBefore: nil, guidedAfter: nil).isEmpty)
        #expect(cues.phrases(for: at(1_610, 480), guidedBefore: nil, guidedAfter: nil).count == 1)
    }

    @Test("With splits switched off nothing is said, and the next split still counts from here")
    func splitsOff() {
        var cues = WatchRunCues(unit: .metric, speaksSplits: false, speaksSteps: true)
        #expect(cues.phrases(for: at(1_005, 300), guidedBefore: nil, guidedAfter: nil).isEmpty)
    }

    @Test("A new step is announced in the phone's words")
    func stepStart() {
        var cues = WatchRunCues(unit: .metric, speaksSplits: false, speaksSteps: true)
        let before = guided
        var after = before
        _ = cues.phrases(for: at(990, 297), guidedBefore: before, guidedAfter: before)
        #expect(after.update(with: at(1_000, 300)) == 1)

        let phrases = cues.phrases(for: at(1_000, 300), guidedBefore: before, guidedAfter: after)

        #expect(phrases == [GuidedStepAnnouncement.stepStart(after.currentStep, unit: .metric)])
    }

    @Test("The heads-up near the end of a rep is spoken once")
    func headsUp() {
        var cues = WatchRunCues(unit: .metric, speaksSplits: false, speaksSteps: true)
        var run = guided
        _ = run.update(with: at(1_000, 300)) // into rep 1
        _ = cues.phrases(for: at(1_250, 360), guidedBefore: run, guidedAfter: run)

        let crossing = cues.phrases(for: at(1_310, 375), guidedBefore: run, guidedAfter: run)
        let after = cues.phrases(for: at(1_330, 380), guidedBefore: run, guidedAfter: run)

        #expect(crossing.count == 1)
        #expect(after.isEmpty)
    }

    @Test("The first step is spoken at the start only when steps are switched on")
    func startPhrase() {
        let on = WatchRunCues(unit: .metric, speaksSplits: false, speaksSteps: true)
        let off = WatchRunCues(unit: .metric, speaksSplits: true, speaksSteps: false)
        let first = GuidedStepAnnouncement.stepStart(guided.currentStep, unit: .metric)
        #expect(on.startPhrase(guided: guided) == first)
        #expect(off.startPhrase(guided: guided) == nil)
        #expect(on.startPhrase(guided: nil) == nil)
    }

    @Test("A session from an older phone build speaks nothing")
    func olderPhoneIsSilent() {
        let session = WatchRunSession(
            sessionID: UUID(), scheduledDate: Date(), title: "Easy",
            targetDistanceMeters: nil, targetPaceLowerSecondsPerKm: nil, targetPaceUpperSecondsPerKm: nil,
            structure: nil, usesRunWalkCues: false, maxHeartRateBPM: nil, usesMetricUnits: true
        )
        #expect(WatchRunCues(session: session, fallbackUnit: .metric).isSilent)
        #expect(WatchRunCues(session: nil, fallbackUnit: .metric).isSilent)
    }
}
