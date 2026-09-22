import Testing
import Foundation
@testable import Stride

// MARK: - Spoken guided-workout cues
//
// The voice coach used to speak splits only; a runner in a 6×800 had to look at the banner
// to learn a rep had ended. These cover what each step sounds like as it starts, and the
// one heads-up near the end of a rep or recovery — in particular that the heads-up fires
// exactly once per step, since the caller keeps no "already said it" flag.

struct GuidedStepAnnouncementTests {

    // MARK: Fixtures

    /// An 800 m rep at 3:55/km, as `GuidedWorkoutState.flatten` emits it.
    private func rep(_ index: Int, of count: Int, meters: Double = 800, pace: Double? = 235) -> GuidedStep {
        GuidedStep(
            kind: .work, label: "VO2max Intervals", target: .distance(meters: meters),
            targetPaceSecondsPerKm: pace, repIndex: index, repCount: count
        )
    }

    private func recovery(_ target: GuidedStep.Target) -> GuidedStep {
        GuidedStep(
            kind: .recovery, label: "Recovery jog", target: target,
            targetPaceSecondsPerKm: nil, repIndex: 1, repCount: 6
        )
    }

    private func remaining(seconds: Double) -> GuidedStepProgress {
        GuidedStepProgress(fraction: 0, isTargetReached: false, remainingDistanceMeters: nil, remainingSeconds: seconds)
    }

    private func remaining(meters: Double) -> GuidedStepProgress {
        GuidedStepProgress(fraction: 0, isTargetReached: false, remainingDistanceMeters: meters, remainingSeconds: nil)
    }

    // MARK: Step start

    @Test("A rep is called by number, with its distance and pace, and ends on Go")
    func repStart() {
        #expect(
            GuidedStepAnnouncement.stepStart(rep(3, of: 6), unit: .metric)
                == "Rep 3 of 6. 800 metres at 3:55 minutes per kilometre. Go."
        )
    }

    @Test("The final rep says so")
    func lastRep() {
        #expect(
            GuidedStepAnnouncement.stepStart(rep(6, of: 6), unit: .metric)
                == "Last rep, 6 of 6. 800 metres at 3:55 minutes per kilometre. Go."
        )
    }

    @Test("An imperial runner hears yards and a per-mile pace")
    func imperialRep() {
        // 800 m ≈ 875 yd, spoken to the nearest ten; 235 s/km ≈ 378 s/mi = 6:18.
        #expect(
            GuidedStepAnnouncement.stepStart(rep(1, of: 4), unit: .imperial)
                == "Rep 1 of 4. 870 yards at 6:18 minutes per mile. Go."
        )
    }

    @Test("A rep with no prescribed pace still gets its distance")
    func repWithoutPace() {
        #expect(
            GuidedStepAnnouncement.stepStart(rep(2, of: 5, pace: nil), unit: .metric)
                == "Rep 2 of 5. 800 metres. Go."
        )
    }

    @Test("A single tempo block is called by its label, not as rep 1 of 1")
    func tempoBlock() {
        let tempo = GuidedStep(
            kind: .work, label: "Tempo", target: .distance(meters: 4_000),
            targetPaceSecondsPerKm: 260, repIndex: nil, repCount: nil
        )
        #expect(
            GuidedStepAnnouncement.stepStart(tempo, unit: .metric)
                == "Tempo. 4 kilometres at 4:20 minutes per kilometre. Go."
        )
    }

    @Test("A timed recovery says how long, in seconds, and carries no pace")
    func timedRecovery() {
        #expect(GuidedStepAnnouncement.stepStart(recovery(.time(seconds: 90)), unit: .metric) == "Recover. 90 seconds.")
    }

    @Test("An open recovery tells the runner how to end it")
    func openRecovery() {
        #expect(
            GuidedStepAnnouncement.stepStart(recovery(.open), unit: .metric)
                == "Recover. Tap Next when you're ready."
        )
    }

    @Test("Warm-up and cool-down say their length but not their easy-pace ceiling")
    func warmupAndCooldown() {
        let warmup = GuidedStep(
            kind: .warmup, label: "Warm-up", target: .distance(meters: 1_000),
            targetPaceSecondsPerKm: 360, repIndex: nil, repCount: nil
        )
        let cooldown = GuidedStep(
            kind: .cooldown, label: "Cool-down", target: .distance(meters: 1_500),
            targetPaceSecondsPerKm: 360, repIndex: nil, repCount: nil
        )
        #expect(GuidedStepAnnouncement.stepStart(warmup, unit: .metric) == "Warm-up. 1 kilometre.")
        #expect(GuidedStepAnnouncement.stepStart(cooldown, unit: .metric) == "Main set done. Cool-down. 1.5 kilometres.")
    }

    // MARK: Spoken amounts

    @Test("Durations are spoken in words, never as a clock reading")
    func durations() {
        #expect(GuidedStepAnnouncement.spokenDuration(seconds: 1) == "1 second")
        #expect(GuidedStepAnnouncement.spokenDuration(seconds: 90) == "90 seconds")
        #expect(GuidedStepAnnouncement.spokenDuration(seconds: 119) == "119 seconds")
        #expect(GuidedStepAnnouncement.spokenDuration(seconds: 120) == "2 minutes")
        #expect(GuidedStepAnnouncement.spokenDuration(seconds: 150) == "2 minutes 30 seconds")
        #expect(GuidedStepAnnouncement.spokenDuration(seconds: 121) == "2 minutes 1 second")
    }

    @Test("Distances are round numbers in the runner's unit")
    func distances() {
        #expect(GuidedStepAnnouncement.spokenDistance(meters: 400, unit: .metric) == "400 metres")
        #expect(GuidedStepAnnouncement.spokenDistance(meters: 1_000, unit: .metric) == "1 kilometre")
        #expect(GuidedStepAnnouncement.spokenDistance(meters: 1_200, unit: .metric) == "1.2 kilometres")
        #expect(GuidedStepAnnouncement.spokenDistance(meters: 2_000, unit: .metric) == "2 kilometres")
        #expect(GuidedStepAnnouncement.spokenDistance(meters: 400, unit: .imperial) == "440 yards")
        // A 1,600 m rep is a mile repeat, not "1750 yards".
        #expect(GuidedStepAnnouncement.spokenDistance(meters: 1_600, unit: .imperial) == "1 mile")
        #expect(GuidedStepAnnouncement.spokenDistance(meters: 1_609.344, unit: .imperial) == "1 mile")
        #expect(GuidedStepAnnouncement.spokenDistance(meters: 2_414.016, unit: .imperial) == "1.5 miles")
    }

    // MARK: Heads-up

    @Test("A timed rep gets a warning as it crosses ten seconds left")
    func timedRepHeadsUp() {
        let step = GuidedStep(
            kind: .work, label: "Hill", target: .time(seconds: 180),
            targetPaceSecondsPerKm: nil, repIndex: 2, repCount: 6
        )
        #expect(
            GuidedStepAnnouncement.headsUp(for: step, from: remaining(seconds: 10.5), to: remaining(seconds: 9.5), unit: .metric)
                == "10 seconds left."
        )
        // Already under the threshold on both ticks: said last tick, not again.
        #expect(GuidedStepAnnouncement.headsUp(for: step, from: remaining(seconds: 9.5), to: remaining(seconds: 8.5), unit: .metric) == nil)
    }

    @Test("A timed recovery's warning tells the runner to get ready")
    func recoveryHeadsUp() {
        #expect(
            GuidedStepAnnouncement.headsUp(
                for: recovery(.time(seconds: 90)),
                from: remaining(seconds: 11), to: remaining(seconds: 10), unit: .metric
            ) == "10 seconds. Get ready."
        )
    }

    @Test("A distance rep gets 100 metres, or 100 yards, to go")
    func distanceRepHeadsUp() {
        #expect(
            GuidedStepAnnouncement.headsUp(for: rep(1, of: 6), from: remaining(meters: 104), to: remaining(meters: 97), unit: .metric)
                == "100 metres to go."
        )
        // 100 yd is 91.44 m: 95 m left is still above it for an imperial runner.
        #expect(GuidedStepAnnouncement.headsUp(for: rep(1, of: 6), from: remaining(meters: 104), to: remaining(meters: 95), unit: .imperial) == nil)
        #expect(
            GuidedStepAnnouncement.headsUp(for: rep(1, of: 6), from: remaining(meters: 95), to: remaining(meters: 88), unit: .imperial)
                == "100 yards to go."
        )
    }

    @Test("Short steps, easy running, open steps and the finishing tick get no warning")
    func noHeadsUp() {
        let shortRep = GuidedStep(
            kind: .work, label: "Stride", target: .time(seconds: 20),
            targetPaceSecondsPerKm: nil, repIndex: 1, repCount: 4
        )
        #expect(GuidedStepAnnouncement.headsUp(for: shortRep, from: remaining(seconds: 11), to: remaining(seconds: 9), unit: .metric) == nil)

        // 150 m is under twice the 100 m threshold.
        #expect(GuidedStepAnnouncement.headsUp(for: rep(1, of: 6, meters: 150), from: remaining(meters: 101), to: remaining(meters: 99), unit: .metric) == nil)

        let warmup = GuidedStep(
            kind: .warmup, label: "Warm-up", target: .distance(meters: 1_000),
            targetPaceSecondsPerKm: nil, repIndex: nil, repCount: nil
        )
        #expect(GuidedStepAnnouncement.headsUp(for: warmup, from: remaining(meters: 101), to: remaining(meters: 99), unit: .metric) == nil)

        let open = GuidedStepProgress(fraction: 0, isTargetReached: false, remainingDistanceMeters: nil, remainingSeconds: nil)
        #expect(GuidedStepAnnouncement.headsUp(for: recovery(.open), from: open, to: open, unit: .metric) == nil)

        // A GPS jump straight past the threshold to the end: the step is over, and its
        // start cue for the next one is about to play.
        #expect(GuidedStepAnnouncement.headsUp(for: rep(1, of: 6), from: remaining(meters: 120), to: remaining(meters: 0), unit: .metric) == nil)
    }

    @Test("Driven by the real stepper, a rep's heads-up fires exactly once")
    func headsUpOncePerRepFromState() throws {
        let warmup = WorkoutSegment(distanceMeters: 1_000, durationSeconds: nil, targetPaceSecondsPerKm: 360, label: "Warm-up")
        let work = WorkoutSegment(distanceMeters: 800, durationSeconds: nil, targetPaceSecondsPerKm: 235, label: "")
        let recovery = WorkoutSegment(distanceMeters: nil, durationSeconds: 90, targetPaceSecondsPerKm: nil, label: "Recovery jog")
        let set = WorkoutSet(repetitions: 3, workSegment: work, recoverySegment: recovery, label: "VO2max Intervals")
        let cooldown = WorkoutSegment(distanceMeters: 1_000, durationSeconds: nil, targetPaceSecondsPerKm: 360, label: "Cool-down")
        let structure = WorkoutStructure(
            warmup: warmup, mainSets: [set], cooldown: cooldown,
            totalEstimatedDistanceMeters: 4_400, totalEstimatedDurationSeconds: 1_800
        )
        var state = try #require(GuidedWorkoutState(structure: structure))
        state.advance(cumulativeDistanceMeters: 1_000, cumulativeElapsedSeconds: 360)
        #expect(state.currentStep.kind == .work)

        // Uneven GPS ticks through the 800, from the step's start to just short of its end.
        var cues: [String] = []
        var previous = state.progress(cumulativeDistanceMeters: 1_000, cumulativeElapsedSeconds: 360)
        var distance = 1_000.0
        var elapsed = 360.0
        while distance < 1_795 {
            distance += 7.3
            elapsed += 1.9
            let now = state.progress(cumulativeDistanceMeters: distance, cumulativeElapsedSeconds: elapsed)
            if let cue = GuidedStepAnnouncement.headsUp(for: state.currentStep, from: previous, to: now, unit: .metric) {
                cues.append(cue)
            }
            previous = now
        }
        #expect(cues == ["100 metres to go."])
    }
}
