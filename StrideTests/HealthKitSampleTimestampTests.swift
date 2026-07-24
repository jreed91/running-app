import Testing
import Foundation
@testable import Stride

/// Covers how stored sample arrays are laid back out over a workout's duration when
/// exporting to HealthKit. Heart-rate readings and route points are persisted as
/// bare ordered arrays with no timestamps of their own, so the export has to
/// reconstruct them — previously it exported neither and Apple Health showed a run
/// with a distance and nothing else.
struct HealthKitSampleTimestampTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Timestamps span the whole workout, inclusive of both ends")
    func timestampsSpanTheWorkout() {
        let end = start.addingTimeInterval(3_600)

        let stamps = HealthKitRepository.sampleTimestamps(count: 5, start: start, end: end)

        #expect(stamps.count == 5)
        #expect(stamps.first == start)
        #expect(stamps.last == end)
    }

    @Test("Samples are spaced evenly")
    func spacingIsEven() {
        let end = start.addingTimeInterval(100)

        let stamps = HealthKitRepository.sampleTimestamps(count: 5, start: start, end: end)

        let gaps = zip(stamps, stamps.dropFirst()).map { $1.timeIntervalSince($0) }
        #expect(gaps.allSatisfy { abs($0 - 25) < 0.000_001 })
    }

    @Test("Timestamps are monotonically increasing, as HealthKit requires")
    func timestampsAreOrdered() {
        let stamps = HealthKitRepository.sampleTimestamps(
            count: 250,
            start: start,
            end: start.addingTimeInterval(1_800)
        )

        #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("A single sample lands at the workout start")
    func singleSampleUsesStart() {
        let stamps = HealthKitRepository.sampleTimestamps(
            count: 1,
            start: start,
            end: start.addingTimeInterval(600)
        )

        #expect(stamps == [start])
    }

    @Test("No samples produces no timestamps")
    func emptyProducesEmpty() {
        #expect(HealthKitRepository.sampleTimestamps(count: 0, start: start, end: start).isEmpty)
        #expect(HealthKitRepository.sampleTimestamps(count: -3, start: start, end: start).isEmpty)
    }

    @Test("A zero-length workout collapses every sample onto the start instant")
    func zeroDurationDoesNotDivideByZero() {
        let stamps = HealthKitRepository.sampleTimestamps(count: 4, start: start, end: start)

        #expect(stamps == [start, start, start, start])
    }

    @Test("An end before the start is clamped rather than running time backwards")
    func reversedRangeIsClamped() {
        let stamps = HealthKitRepository.sampleTimestamps(
            count: 3,
            start: start,
            end: start.addingTimeInterval(-600)
        )

        #expect(stamps == [start, start, start])
    }
}
