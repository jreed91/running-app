import Foundation
import SwiftData
import Testing
@preconcurrency import WorkoutKit
@testable import Stride

// MARK: - Custom workouts (PR 5): the library on the Watch, and the runs it records

@MainActor
struct CustomWorkoutWatchTests {

    private func structure(reps: Int = 6) -> WorkoutStructure {
        CustomWorkoutRules.finalized(WorkoutStructure(
            warmup: WorkoutSegment(durationSeconds: 600, label: "Warm-up"),
            mainSets: [WorkoutSet(
                repetitions: reps,
                workSegment: WorkoutSegment(distanceMeters: 800, targetPaceSecondsPerKm: 240, label: ""),
                recoverySegment: WorkoutSegment(durationSeconds: 90, label: "Jog"),
                label: ""
            )],
            cooldown: WorkoutSegment(label: ""),
            totalEstimatedDistanceMeters: 0,
            totalEstimatedDurationSeconds: 0
        ))
    }

    private func workout(_ name: String, updated: TimeInterval, used: TimeInterval? = nil) -> SavedWorkout {
        let saved = SavedWorkout(name: name, structure: structure(), now: Date(timeIntervalSince1970: updated))
        if let used { saved.markUsed(now: Date(timeIntervalSince1970: used)) }
        return saved
    }

    // MARK: Sessions sent

    @Test("Workouts go to the Watch most recently used first, then most recently edited")
    func ordering() {
        let edited = workout("Edited", updated: 3_000)
        let used = workout("Used", updated: 1_000, used: 2_000)
        let old = workout("Old", updated: 500)
        let sessions = WatchSyncService.customWorkoutSessions(
            for: [old, edited, used], unit: .metric, maxHeartRateBPM: 190, spokenCues: (true, true)
        )
        #expect(sessions.map(\.title) == ["Used", "Edited", "Old"])
        #expect(sessions.first?.sessionID == used.id)
        #expect(sessions.first?.structure == used.structure)
        #expect(sessions.first?.guidedState() != nil)
    }

    @Test("A workout with no structure is not sent, and the list is capped")
    func skipsAndCaps() {
        let broken = workout("Broken", updated: 9_999)
        broken.structureData = nil
        let many = (0..<15).map { workout("W\($0)", updated: Double($0)) }
        let sessions = WatchSyncService.customWorkoutSessions(
            for: [broken] + many, unit: .imperial, maxHeartRateBPM: nil, spokenCues: (false, false)
        )
        #expect(sessions.count == WatchContext.maxCustomWorkouts)
        #expect(!sessions.contains { $0.title == "Broken" })
        #expect(sessions.allSatisfy { !$0.usesMetricUnits && $0.maxHeartRateBPM == nil })
    }

    // MARK: Envelope

    @Test("The library rides in the application context and comes back the same")
    func contextRoundTrip() throws {
        let sessions = WatchSyncService.customWorkoutSessions(
            for: [workout("A", updated: 1), workout("B", updated: 2)],
            unit: .metric, maxHeartRateBPM: 185, spokenCues: (true, false)
        )
        let original = WatchContext(snapshot: .sample(), customWorkouts: sessions)
        let decoded = try #require(WatchContext(applicationContext: try original.applicationContext()))
        #expect(decoded.customWorkouts == sessions)
    }

    @Test("No library sends no key, and an older phone's context reads as none")
    func noLibraryNoKey() throws {
        let dictionary = try WatchContext(snapshot: .sample()).applicationContext()
        #expect(dictionary[WatchContext.Key.customWorkouts] == nil)
        #expect(WatchContext(applicationContext: dictionary)?.customWorkouts.isEmpty == true)
    }

    // MARK: Import

    @Test("A Watch run that names a saved workout is titled with it on import")
    func importNamesTheRun() throws {
        let context = TestStore.makeContext()
        let service = WorkoutSyncService(
            healthKitRepository: MockHealthKitRepository(),
            notificationService: NotificationService.shared,
            weatherService: WeatherService(),
            context: context
        )
        let saved = workout("6 × 800 m", updated: 1_000)
        context.insert(saved)
        try context.save()

        let run = RunWorkout(distanceMeters: 7_000, durationSeconds: 2_400)
        run.date = Date(timeIntervalSince1970: 5_000)
        run.namedSessionID = saved.id
        let other = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_700)
        other.namedSessionID = UUID()

        service.nameCustomWorkoutRuns([run, other])

        #expect(run.customWorkoutName == "6 × 800 m")
        #expect(run.customWorkoutID == saved.id)
        #expect(saved.lastUsedAt == run.date)
        #expect(other.customWorkoutName == nil, "an id that is no saved workout changes nothing")
    }

    // MARK: Workout app (PR 6)

    @Test("A saved workout becomes a Workout app plan with its own id and name")
    func workoutKitPlan() throws {
        let saved = workout("6 × 800 m", updated: 1)
        let plan = try #require(HealthKitRepository.makeWorkoutPlan(for: saved, unitPreference: .metric))
        #expect(plan.id == saved.id)
        guard case .custom(let custom) = plan.workout else {
            Issue.record("expected a custom workout")
            return
        }
        #expect(custom.displayName == "6 × 800 m")
        #expect(custom.cooldown == nil, "a left-out cool-down is not sent")
        #expect(custom.warmup != nil)
    }

    @Test("A saved workout with no steps has no plan")
    func noStepsNoPlan() {
        let saved = workout("Empty", updated: 1)
        saved.structureData = nil
        #expect(HealthKitRepository.makeWorkoutPlan(for: saved, unitPreference: .metric) == nil)
    }
}
