import Testing
@testable import Stride

@Suite("WorkoutSet recovery duration")
struct WorkoutSetDurationTests {

    private func intervalSet(reps: Int, recoverySeconds: Double?) -> WorkoutSet {
        WorkoutSet(
            repetitions: reps,
            workSegment: WorkoutSegment(
                distanceMeters: 800,
                durationSeconds: nil,
                targetPaceSecondsPerKm: 240,
                label: "Interval"
            ),
            recoverySegment: WorkoutSegment(
                distanceMeters: nil,
                durationSeconds: recoverySeconds,
                targetPaceSecondsPerKm: nil,
                label: "Recovery jog"
            ),
            label: "Interval Set"
        )
    }

    @Test("Six reps have five recovery jogs, not six")
    func sixRepsCountFiveRecoveries() {
        // The final rep is followed by the cool-down, not another recovery.
        let set = intervalSet(reps: 6, recoverySeconds: 90)
        #expect(set.totalRecoverySeconds == 5 * 90)
    }

    @Test("A single rep has no recovery")
    func singleRepHasNoRecovery() {
        let set = intervalSet(reps: 1, recoverySeconds: 90)
        #expect(set.totalRecoverySeconds == 0)
    }

    @Test("Zero or negative reps produce no recovery")
    func zeroRepsHaveNoRecovery() {
        #expect(intervalSet(reps: 0, recoverySeconds: 90).totalRecoverySeconds == 0)
    }

    @Test("A recovery segment with no duration contributes nothing")
    func openRecoveryContributesNothing() {
        let set = intervalSet(reps: 6, recoverySeconds: nil)
        #expect(set.totalRecoverySeconds == 0)
    }

    @Test("Recovery scales linearly with rep count")
    func recoveryScalesWithReps() {
        #expect(intervalSet(reps: 4, recoverySeconds: 120).totalRecoverySeconds == 3 * 120)
        #expect(intervalSet(reps: 10, recoverySeconds: 60).totalRecoverySeconds == 9 * 60)
    }
}
