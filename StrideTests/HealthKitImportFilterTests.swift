import Testing
import Foundation
@testable import Stride

// MARK: - HealthKit import shell-filter tests (M11)

struct HealthKitImportFilterTests {

    @Test("A real run with both distance and duration imports")
    func genuineRunImports() {
        #expect(HealthKitRepository.isImportableWorkout(distanceMeters: 5_000, durationSeconds: 1_500))
        #expect(HealthKitRepository.isImportableWorkout(distanceMeters: 150, durationSeconds: 45))
    }

    @Test("A zero-distance workout is rejected even when it ran long enough")
    func zeroDistanceShellRejected() {
        // The old `||` guard admitted any ≥30 s workout regardless of distance,
        // so a 0 m accidental start/stop polluted pace/VDOT stats.
        #expect(!HealthKitRepository.isImportableWorkout(distanceMeters: 0, durationSeconds: 45))
        #expect(!HealthKitRepository.isImportableWorkout(distanceMeters: 80, durationSeconds: 600))
    }

    @Test("A too-short workout is rejected even with some distance")
    func tooShortShellRejected() {
        #expect(!HealthKitRepository.isImportableWorkout(distanceMeters: 200, durationSeconds: 10))
    }

    @Test("A negligible shell is rejected")
    func negligibleShellRejected() {
        #expect(!HealthKitRepository.isImportableWorkout(distanceMeters: 0, durationSeconds: 0))
    }
}
