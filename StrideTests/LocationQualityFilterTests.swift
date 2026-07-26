import Testing
import Foundation
@testable import Stride

// MARK: - GPS quality filtering (N8)
//
// The live tracker used to accept every fix Core Location delivered, so accuracy
// spikes, the cached fix replayed when updates start, and outright GPS jumps were
// all recorded as real distance and drawn into the route.

struct LocationQualityFilterTests {

    private func fix(
        accuracy: Double = 5,
        age: TimeInterval = 0,
        distance: Double? = nil,
        interval: TimeInterval? = nil
    ) -> LocationQualityFilter.Fix {
        LocationQualityFilter.Fix(
            horizontalAccuracy: accuracy,
            ageSeconds: age,
            distanceFromPreviousMeters: distance,
            secondsSincePreviousFix: interval
        )
    }

    @Test("A clean fix is accepted")
    func cleanFixAccepted() {
        #expect(LocationQualityFilter.accepts(fix()))
        // 5 m in 1 s ≈ 3:20/km — an ordinary fix at the manager's distance filter.
        #expect(LocationQualityFilter.accepts(fix(distance: 5, interval: 1)))
    }

    @Test("A negative horizontal accuracy means the reading is invalid")
    func negativeAccuracyRejected() {
        #expect(LocationQualityFilter.rejection(for: fix(accuracy: -1)) == .invalidAccuracy)
    }

    @Test("Imprecise fixes are rejected at the accuracy ceiling, not below it")
    func poorAccuracyRejected() {
        let limit = LocationQualityFilter.maximumHorizontalAccuracyMeters
        #expect(LocationQualityFilter.accepts(fix(accuracy: limit)))
        #expect(LocationQualityFilter.rejection(for: fix(accuracy: limit + 0.1)) == .poorAccuracy)
        // The case the auto-pause guard could never catch: a wide-accuracy fix that
        // implies fast movement, which used to be kept as distance.
        #expect(LocationQualityFilter.rejection(for: fix(accuracy: 40, distance: 30, interval: 2)) == .poorAccuracy)
    }

    @Test("The cached fix replayed when updates start is rejected as stale")
    func staleFixRejected() {
        let limit = LocationQualityFilter.maximumFixAgeSeconds
        #expect(LocationQualityFilter.accepts(fix(age: limit)))
        #expect(LocationQualityFilter.rejection(for: fix(age: limit + 1)) == .stale)
        #expect(LocationQualityFilter.rejection(for: fix(age: 600)) == .stale)
    }

    @Test("A fix that took a moment to be delivered is still live data")
    func slightDelayAccepted() {
        #expect(LocationQualityFilter.accepts(fix(age: 2)))
        // Clock skew can make a fix look like it came from the future.
        #expect(LocationQualityFilter.accepts(fix(age: -1)))
    }

    @Test("A fix older than the last accepted one is out of order")
    func outOfOrderRejected() {
        #expect(LocationQualityFilter.rejection(for: fix(distance: 10, interval: -3)) == .outOfOrder)
    }

    @Test("A jump implying an impossible speed is rejected")
    func impossibleSpeedRejected() {
        // 100 m between two fixes one second apart.
        #expect(LocationQualityFilter.rejection(for: fix(distance: 100, interval: 1)) == .impossibleSpeed)
        // Two fixes sharing a timestamp but not a position: infinitely fast.
        #expect(LocationQualityFilter.rejection(for: fix(distance: 20, interval: 0)) == .impossibleSpeed)
    }

    @Test("Genuinely fast running is not mistaken for a GPS jump")
    func fastRunningAccepted() {
        // 6 m/s ≈ 2:47/km — a sprint finish, comfortably under the cap.
        #expect(LocationQualityFilter.accepts(fix(distance: 6, interval: 1)))
        // A long reception gap covers real distance at a plausible speed.
        #expect(LocationQualityFilter.accepts(fix(distance: 300, interval: 60)))
    }

    @Test("A stationary fix is not rejected for speed")
    func stationaryFixAccepted() {
        #expect(LocationQualityFilter.accepts(fix(distance: 0, interval: 0)))
        #expect(LocationQualityFilter.accepts(fix(distance: 0, interval: 5)))
    }

    @Test("The first fix of a segment has nothing to compare against")
    func firstFixAccepted() {
        #expect(LocationQualityFilter.accepts(fix(distance: nil, interval: nil)))
        #expect(LocationQualityFilter.rejection(for: fix(accuracy: 100, distance: nil, interval: nil)) == .poorAccuracy)
    }

    @Test("Accuracy is checked before staleness and speed, so the reason is the worst problem")
    func rejectionPrecedence() {
        #expect(
            LocationQualityFilter.rejection(for: fix(accuracy: -1, age: 900, distance: 500, interval: 1))
                == .invalidAccuracy
        )
    }

    // MARK: - Signal quality (U5c)

    @Test("Signal quality grades from the horizontal accuracy reading")
    func signalQualityGrades() {
        #expect(LocationQualityFilter.signalQuality(forHorizontalAccuracy: 0) == .strong)
        #expect(LocationQualityFilter.signalQuality(forHorizontalAccuracy: 5) == .strong)
        #expect(LocationQualityFilter.signalQuality(forHorizontalAccuracy: 9) == .fair)
        #expect(LocationQualityFilter.signalQuality(forHorizontalAccuracy: 40) == .weak)
    }

    @Test("The grade boundaries are inclusive, and meet the filter's own ceiling")
    func signalQualityBoundaries() {
        let strongCeiling = LocationQualityFilter.strongHorizontalAccuracyMeters
        let acceptCeiling = LocationQualityFilter.maximumHorizontalAccuracyMeters
        #expect(LocationQualityFilter.signalQuality(forHorizontalAccuracy: strongCeiling) == .strong)
        #expect(LocationQualityFilter.signalQuality(forHorizontalAccuracy: strongCeiling.nextUp) == .fair)
        // The fair/weak boundary is the same reading that starts rejecting fixes, so
        // "weak" means "distance is being under-counted", not merely "imprecise".
        #expect(LocationQualityFilter.signalQuality(forHorizontalAccuracy: acceptCeiling) == .fair)
        #expect(LocationQualityFilter.accepts(fix(accuracy: acceptCeiling)))
        #expect(LocationQualityFilter.signalQuality(forHorizontalAccuracy: acceptCeiling.nextUp) == .weak)
        #expect(!LocationQualityFilter.accepts(fix(accuracy: acceptCeiling.nextUp)))
    }

    @Test("An unusable reading is weak, not strong")
    func invalidAccuracyIsWeak() {
        // `horizontalAccuracy` is negative when Core Location cannot fix the position
        // at all. Grading that as 0 metres would have shown three bars for no signal.
        #expect(LocationQualityFilter.signalQuality(forHorizontalAccuracy: -1) == .weak)
        #expect(LocationQualityFilter.signalQuality(forHorizontalAccuracy: .nan) == .weak)
        #expect(LocationQualityFilter.signalQuality(forHorizontalAccuracy: .infinity) == .weak)
    }

    @Test("Each grade fills a distinct number of bars, so the indicator reads without colour")
    func signalQualityBarsAreDistinct() {
        let bars = LocationQualityFilter.SignalQuality.allCases.map(\.bars)
        #expect(Set(bars).count == LocationQualityFilter.SignalQuality.allCases.count)
        #expect(bars.allSatisfy { (1...3).contains($0) })
        #expect(LocationQualityFilter.SignalQuality.strong.bars > LocationQualityFilter.SignalQuality.weak.bars)
    }
}
