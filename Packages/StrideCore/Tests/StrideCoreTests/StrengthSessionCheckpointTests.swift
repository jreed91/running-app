import Foundation
import Testing
@testable import StrideCore

/// Covers `StrengthSessionCheckpoint`: which interrupted session reopens, and that it
/// survives the trip through storage.
struct StrengthSessionCheckpointTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let scheduledID = UUID()

    private func checkpoint(
        scheduledID: UUID?,
        savedMinutesAgo: Double = 10,
        sets: [CompletedStrengthSet]? = nil
    ) -> StrengthSessionCheckpoint {
        let plan = StrengthLibrary.plan(for: [.dumbbells], focus: .generalStrength, phase: .build)
        return StrengthSessionCheckpoint(
            scheduledWorkoutID: scheduledID,
            plan: plan,
            swaps: [1: plan.exercises[0]],
            completedSets: sets ?? [
                CompletedStrengthSet(exerciseIndex: 0, setIndex: 0, completedReps: 10, actualWeight: "20 kg",
                                     skipped: false, exerciseName: plan.exercises[0].name, weightKilograms: 20),
            ],
            currentExerciseIndex: 0,
            currentSetIndex: 1,
            startTime: now.addingTimeInterval(-savedMinutesAgo * 60 - 300),
            savedAt: now.addingTimeInterval(-savedMinutesAgo * 60)
        )
    }

    @Test func resumesTheSameScheduledSession() {
        #expect(checkpoint(scheduledID: scheduledID).resumes(scheduledWorkoutID: scheduledID, now: now))
        #expect(!checkpoint(scheduledID: scheduledID).resumes(scheduledWorkoutID: UUID(), now: now))
        #expect(!checkpoint(scheduledID: scheduledID).resumes(scheduledWorkoutID: nil, now: now))
    }

    @Test func unplannedResumesUnplanned() {
        #expect(checkpoint(scheduledID: nil).resumes(scheduledWorkoutID: nil, now: now))
        #expect(!checkpoint(scheduledID: nil).resumes(scheduledWorkoutID: scheduledID, now: now))
    }

    @Test func staleOrEmptyCheckpointsDoNotResume() {
        #expect(!checkpoint(scheduledID: nil, savedMinutesAgo: 7 * 60).resumes(scheduledWorkoutID: nil, now: now))
        let skippedOnly = [CompletedStrengthSet(exerciseIndex: 0, setIndex: 0, completedReps: 0, actualWeight: nil, skipped: true)]
        #expect(!checkpoint(scheduledID: nil, sets: skippedOnly).resumes(scheduledWorkoutID: nil, now: now))
    }

    @Test func roundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "StrengthSessionCheckpointTests"))
        defer { defaults.removePersistentDomain(forName: "StrengthSessionCheckpointTests") }
        let saved = checkpoint(scheduledID: scheduledID)
        saved.save(to: defaults)
        #expect(StrengthSessionCheckpoint.load(from: defaults) == saved)
        StrengthSessionCheckpoint.clear(from: defaults)
        #expect(StrengthSessionCheckpoint.load(from: defaults) == nil)
    }
}
