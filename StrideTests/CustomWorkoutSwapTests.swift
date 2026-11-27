import Foundation
import Testing
@testable import Stride

// MARK: - Custom workouts (PR 4): swapping one onto a plan day

struct CustomWorkoutSwapTests {

    private func eights() -> WorkoutStructure {
        CustomWorkoutRules.finalized(WorkoutStructure(
            warmup: WorkoutSegment(durationSeconds: 600, label: "Warm-up"),
            mainSets: [WorkoutSet(
                repetitions: 6,
                workSegment: WorkoutSegment(distanceMeters: 800, targetPaceSecondsPerKm: 240, label: ""),
                recoverySegment: WorkoutSegment(durationSeconds: 90, label: "Jog"),
                label: ""
            )],
            cooldown: WorkoutSegment(durationSeconds: 600, label: "Cool-down"),
            totalEstimatedDistanceMeters: 0,
            totalEstimatedDurationSeconds: 0
        ))
    }

    private func easyDay() -> ScheduledWorkout {
        let day = ScheduledWorkout(
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            workoutType: .easy,
            targetDistanceMeters: 8_000,
            targetPaceLowerBound: 330,
            targetPaceUpperBound: 360,
            notes: "Keep it conversational."
        )
        day.healthKitPlanID = "old"
        return day
    }

    @Test("Swapping puts the workout's steps on the day and keeps the day")
    func swapReplacesWhatIsRun() {
        let day = easyDay()
        let date = day.scheduledDate
        let id = day.id
        let structure = eights()

        day.applyCustomWorkout(name: "6 × 800 m", structure: structure, notes: "Track")

        #expect(day.id == id && day.scheduledDate == date && !day.isCompleted)
        #expect(day.workoutType == .interval)
        #expect(day.workoutStructure == structure)
        #expect(day.targetDistanceMeters == structure.totalEstimatedDistanceMeters)
        #expect(day.targetPaceRange == nil, "the reps carry their own paces")
        #expect(day.notes == "Track", "the coach's note described the old session")
        #expect(day.healthKitPlanID == nil, "the Workout app copy is rebuilt")
        #expect(day.displayTitle == "6 × 800 m")
        #expect(AdaptedSessions.protectedIDs().contains(id))
    }

    @Test("A workout with no notes leaves the day with none")
    func swapWithoutNotes() {
        let day = easyDay()
        day.applyCustomWorkout(name: "x", structure: eights(), notes: "")
        #expect(day.notes == nil)
    }

    @Test("The coach rewriting the day drops the custom name")
    func adaptationClearsTheName() {
        let day = easyDay()
        day.applyCustomWorkout(name: "6 × 800 m", structure: eights(), notes: nil)

        let adapted = ScheduledWorkout(scheduledDate: day.scheduledDate, workoutType: .tempo, targetDistanceMeters: 6_000)
        day.applyAdaptation(from: adapted)

        #expect(day.customWorkoutName == nil)
        #expect(day.displayTitle == WorkoutType.tempo.localizedName)
    }
}
