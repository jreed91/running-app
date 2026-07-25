import Testing
import Foundation
@testable import Stride

// MARK: - Imported workout-type inference (N10)
//
// HealthKit has no concept of Easy/Tempo/LongRun. The importer used to approximate
// with one absolute threshold (`< 5:20/km ⇒ tempo`), which labelled a fast runner's
// easy runs "Tempo" — inflating the VO₂-max trend, which only samples quality
// sessions — and never produced a quality session for a slower runner, so their
// estimated VO₂-max chart stayed empty however much they ran.

struct WorkoutTypeInferenceTests {

    /// A 20-minute 5 K runner: easy ≈ 4:55–5:53/km, marathon ≈ 4:39/km.
    private let fastRunner = PaceCalculatorService.trainingPaces(from5KTimeSeconds: 1_200)
    /// A 30-minute 5 K runner: easy ≈ 7:11–8:32/km, marathon ≈ 6:49/km.
    private let newRunner = PaceCalculatorService.trainingPaces(from5KTimeSeconds: 1_800)

    private func type(
        km: Double,
        paceSecondsPerKm: Double,
        paces: TrainingPaces?
    ) -> WorkoutType {
        HealthKitRepository.inferWorkoutType(
            distanceMeters: km * 1_000,
            durationSeconds: km * paceSecondsPerKm,
            paces: paces
        )
    }

    @Test("A fast runner's easy run is no longer called a tempo")
    func fastRunnerEasyRun() {
        // 5:30/km — comfortably inside this runner's easy band, but faster than the
        // old absolute 5:20/km-ish threshold applied to everyone.
        #expect(type(km: 8, paceSecondsPerKm: 330, paces: fastRunner) == .easy)
        #expect(type(km: 8, paceSecondsPerKm: 300, paces: fastRunner) == .easy)
    }

    @Test("A fast runner's genuine quality session is a tempo")
    func fastRunnerTempo() {
        // 4:15/km — inside threshold pace for this runner.
        #expect(type(km: 8, paceSecondsPerKm: 255, paces: fastRunner) == .tempo)
    }

    @Test("A newer runner can produce a quality session at their own paces")
    func newRunnerTempo() {
        // 6:00/km is easy for the fast runner's standards and impossible to classify
        // as quality under the old absolute rule, but it is a hard effort here.
        #expect(type(km: 5, paceSecondsPerKm: 360, paces: newRunner) == .tempo)
        #expect(type(km: 5, paceSecondsPerKm: 360, paces: fastRunner) == .easy)
    }

    @Test("A newer runner's easy run stays easy")
    func newRunnerEasyRun() {
        #expect(type(km: 5, paceSecondsPerKm: 480, paces: newRunner) == .easy)
    }

    @Test("Distance still decides a long run, at any pace")
    func longRunByDistance() {
        #expect(type(km: 16, paceSecondsPerKm: 330, paces: fastRunner) == .longRun)
        #expect(type(km: 22, paceSecondsPerKm: 255, paces: fastRunner) == .longRun)
        #expect(type(km: 18, paceSecondsPerKm: 400, paces: nil) == .longRun)
        #expect(type(km: 15.9, paceSecondsPerKm: 330, paces: fastRunner) == .easy)
    }

    @Test("With no pace estimate for the runner, a run is easy rather than guessed at")
    func unknownRunnerDefaultsToEasy() {
        #expect(type(km: 5, paceSecondsPerKm: 240, paces: nil) == .easy)
        #expect(type(km: 10, paceSecondsPerKm: 600, paces: nil) == .easy)
    }

    @Test("Degenerate workouts never divide by zero")
    func degenerateWorkouts() {
        #expect(
            HealthKitRepository.inferWorkoutType(distanceMeters: 0, durationSeconds: 600, paces: fastRunner)
                == .easy
        )
        #expect(
            HealthKitRepository.inferWorkoutType(distanceMeters: 5_000, durationSeconds: 0, paces: fastRunner)
                == .easy
        )
    }

    @Test("Marathon pace is the quality boundary, and it sits clear of the easy band")
    func boundaryIsMarathonPace() {
        for paces in [fastRunner, newRunner] {
            #expect(type(km: 10, paceSecondsPerKm: paces.marathon - 1, paces: paces) == .tempo)
            #expect(type(km: 10, paceSecondsPerKm: paces.marathon + 1, paces: paces) == .easy)
            // The fastest end of the runner's own easy range must not read as quality.
            #expect(type(km: 10, paceSecondsPerKm: paces.easyRange.lowerBound, paces: paces) == .easy)
        }
    }
}
