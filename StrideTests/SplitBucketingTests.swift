import Testing
import Foundation
@testable import Stride

// MARK: - RunWorkout split-unit tagging

struct RunWorkoutSplitUnitTests {

    @Test("Legacy runs default to metric split unit")
    func defaultsToMetric() {
        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_500)
        #expect(run.splitUnit == .metric)
        #expect(run.splitUnitRaw == UnitPreference.metric.rawValue)
    }

    @Test("Split unit round-trips through the raw field")
    func splitUnitRoundTrips() {
        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_500)
        run.splitUnit = .imperial
        #expect(run.splitUnitRaw == "imperial")
        #expect(run.splitUnit == .imperial)
    }
}
