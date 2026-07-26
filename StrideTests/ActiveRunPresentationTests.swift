import Testing
import Foundation
@testable import Stride

// MARK: - Minimising an active run (U7)
//
// The run HUD moved off `DashboardView` and onto `MainTabView` so it can be minimised
// into the tab-bar accessory instead of only finished or discarded. Dismissing a cover
// destroys the view inside it, so everything the run remembers that the tracker does not
// had to move out of `@State` — and the point of these tests is that it *survives*:
// a runner three intervals into a structured session must come back to step 4, not step 1.

@MainActor
struct ActiveRunPresentationTests {

    // MARK: Fixtures

    /// An interval session — 1 km warm-up, 3 × (800 m work + 90 s recovery), 1 km
    /// cool-down — carried by a scheduled workout, which is the only shape that produces
    /// a guided stepper.
    private func intervalWorkout(reps: Int = 3) -> ScheduledWorkout {
        let work = WorkoutSegment(
            distanceMeters: 800, durationSeconds: nil,
            targetPaceSecondsPerKm: 235, label: ""
        )
        let recovery = WorkoutSegment(
            distanceMeters: nil, durationSeconds: 90,
            targetPaceSecondsPerKm: nil, label: "Recovery jog"
        )
        let workout = ScheduledWorkout(scheduledDate: Date(), workoutType: .interval)
        workout.workoutStructure = WorkoutStructure(
            warmup: WorkoutSegment(
                distanceMeters: 1_000, durationSeconds: nil,
                targetPaceSecondsPerKm: 360, label: "Warm-up"
            ),
            mainSets: [
                WorkoutSet(
                    repetitions: reps, workSegment: work,
                    recoverySegment: recovery, label: "VO2max Intervals"
                )
            ],
            cooldown: WorkoutSegment(
                distanceMeters: 1_000, durationSeconds: nil,
                targetPaceSecondsPerKm: 360, label: "Cool-down"
            ),
            totalEstimatedDistanceMeters: 4_400,
            totalEstimatedDurationSeconds: 1_800
        )
        return workout
    }

    // MARK: Starting

    @Test("A free run presents the HUD with no session state behind it")
    func startFreeRun() {
        let presentation = ActiveRunPresentation()
        presentation.start(scheduledWorkout: nil)

        #expect(presentation.isPresented)
        #expect(presentation.scheduledWorkout == nil)
        #expect(presentation.guided == nil)
    }

    @Test("A structured workout builds its guided stepper once, at the start")
    func startBuildsGuidedStepper() {
        let presentation = ActiveRunPresentation()
        presentation.start(scheduledWorkout: intervalWorkout())

        #expect(presentation.isPresented)
        #expect(presentation.scheduledWorkout != nil)
        // 1 warm-up + 3 × (work + recovery) + 1 cool-down.
        #expect(presentation.guided?.stepCount == 8)
        #expect(presentation.guided?.stepNumber == 1)
    }

    @Test("A flat run gets no stepper, even though it is a scheduled workout")
    func flatScheduledRunHasNoStepper() {
        let presentation = ActiveRunPresentation()
        let easy = ScheduledWorkout(scheduledDate: Date(), workoutType: .easy)

        presentation.start(scheduledWorkout: easy)

        #expect(presentation.scheduledWorkout != nil)
        #expect(presentation.guided == nil)
    }

    // MARK: Minimising

    @Test("Minimising closes the HUD and keeps the session")
    func minimizeKeepsTheSession() {
        let presentation = ActiveRunPresentation()
        presentation.start(scheduledWorkout: intervalWorkout())

        presentation.minimize()

        #expect(!presentation.isPresented)
        #expect(presentation.scheduledWorkout != nil)
        #expect(presentation.guided != nil)
    }

    @Test("Reopening a minimised run resumes the stepper where it was, not at step 1")
    func reopenPreservesStepperPosition() {
        let presentation = ActiveRunPresentation()
        presentation.start(scheduledWorkout: intervalWorkout())

        // Three steps in: warm-up, first work rep, first recovery.
        for _ in 0..<3 {
            presentation.guided?.advance(cumulativeDistanceMeters: 0, cumulativeElapsedSeconds: 0)
        }
        #expect(presentation.guided?.stepNumber == 4)

        presentation.minimize()
        presentation.reopen()

        #expect(presentation.isPresented)
        // This is the regression the whole change hinges on: rebuilding the stepper on
        // reopen — which is what the HUD's `onAppear` used to do — would read 1 here.
        #expect(presentation.guided?.stepNumber == 4)
    }

    // MARK: Starting while a run is already going

    @Test("A start control tapped while a run is recording reopens it, and replaces nothing")
    func startWhileRecordingReopens() {
        let presentation = ActiveRunPresentation()
        let planned = intervalWorkout()
        presentation.start(scheduledWorkout: planned)
        presentation.guided?.advance(cumulativeDistanceMeters: 1_000, cumulativeElapsedSeconds: 360)
        presentation.minimize()

        // The dashboard's free-run button is live underneath a minimised run.
        presentation.startOrReopen(scheduledWorkout: nil, isRunInProgress: true)

        #expect(presentation.isPresented)
        // Still the planned session, still on the step the runner is actually running.
        #expect(presentation.scheduledWorkout === planned)
        #expect(presentation.guided?.stepNumber == 2)
    }

    @Test("With nothing recording, a start control starts a fresh session")
    func startWhenNothingIsRecording() {
        let presentation = ActiveRunPresentation()
        presentation.start(scheduledWorkout: intervalWorkout())
        presentation.end()

        presentation.startOrReopen(scheduledWorkout: nil, isRunInProgress: false)

        #expect(presentation.isPresented)
        #expect(presentation.scheduledWorkout == nil)
        #expect(presentation.guided == nil)
    }

    // MARK: Ending

    @Test("Ending clears the session as well as closing the HUD")
    func endClearsTheSession() {
        let presentation = ActiveRunPresentation()
        presentation.start(scheduledWorkout: intervalWorkout())

        presentation.end()

        #expect(!presentation.isPresented)
        #expect(presentation.scheduledWorkout == nil)
        #expect(presentation.guided == nil)
    }

    @Test("A free run started after a planned one inherits nothing from it")
    func startingAFreeRunClearsThePreviousSession() {
        let presentation = ActiveRunPresentation()
        presentation.start(scheduledWorkout: intervalWorkout())
        presentation.end()

        presentation.start(scheduledWorkout: nil)

        // A leaked scheduled workout would link the free run to a plan day and mark it
        // complete (H4), so `start` has to clear as thoroughly as `end` does.
        #expect(presentation.scheduledWorkout == nil)
        #expect(presentation.guided == nil)
    }
}
