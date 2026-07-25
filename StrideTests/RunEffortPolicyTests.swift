import Foundation
import Testing
@testable import Stride

/// Covers the shared minimum-effort floor (N17). A mis-tapped run used to be saved,
/// exported, and allowed to complete a planned session; the importer's floor now
/// applies to app-recorded runs too, and both paths read it from one place.
struct RunEffortPolicyTests {

    @Test("A real run clears the floor")
    func realRunClearsTheFloor() {
        #expect(RunEffortPolicy.isRealRun(distanceMeters: 5_000, durationSeconds: 1_500))
        #expect(RunEffortPolicy.isRealRun(distanceMeters: 150, durationSeconds: 45))
    }

    @Test("A mis-tapped run does not clear the floor")
    func misTapDoesNotClearTheFloor() {
        // The exact shape N17 describes: start by accident, stop twelve seconds later.
        #expect(!RunEffortPolicy.isRealRun(distanceMeters: 30, durationSeconds: 12))
        #expect(!RunEffortPolicy.isRealRun(distanceMeters: 0, durationSeconds: 600))
        #expect(!RunEffortPolicy.isRealRun(distanceMeters: 900, durationSeconds: 20))
        #expect(!RunEffortPolicy.isRealRun(distanceMeters: 0, durationSeconds: 0))
    }

    @Test("The importer and the in-app finish path share one floor")
    func importerDelegatesToThePolicy() {
        let cases: [(Double, Double)] = [
            (5_000, 1_500),
            (150, 45),
            (30, 12),
            (100, 30),      // boundary: distance must exceed the minimum
            (101, 30),
            (101, 29),
        ]
        for (distance, duration) in cases {
            #expect(
                HealthKitRepository.isImportableWorkout(distanceMeters: distance, durationSeconds: duration)
                    == RunEffortPolicy.isRealRun(distanceMeters: distance, durationSeconds: duration)
            )
        }
    }

    @Test("A sub-floor run may not complete a scheduled workout")
    func subFloorRunCannotCompleteAScheduledWorkout() {
        let misTap = RunWorkout(date: Date(), distanceMeters: 40, durationSeconds: 12, workoutType: .easy)
        let realRun = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 2_400, workoutType: .easy)

        #expect(!RunEffortPolicy.canCompleteScheduledWorkout(misTap))
        #expect(RunEffortPolicy.canCompleteScheduledWorkout(realRun))
    }
}
