import Foundation
import Testing
@testable import Stride

/// Covers `HealthImportChunks`: a long import range read a stretch at a time.
struct HealthImportChunksTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func coversTheWholeRangeNewestFirstWithoutGaps() {
        let start = now.addingTimeInterval(-5 * 365 * 86_400)
        let ranges = HealthImportChunks.ranges(from: start, to: now)
        #expect(ranges.first?.end == now)
        #expect(ranges.last?.start == start)
        for (newer, older) in zip(ranges, ranges.dropFirst()) {
            #expect(older.end == newer.start)
        }
        #expect(ranges.allSatisfy { $0.duration <= 30 * 86_400 })
        #expect(ranges.count == 61)
    }

    @Test func aShortRangeIsOneStretch() {
        let start = now.addingTimeInterval(-3 * 86_400)
        #expect(HealthImportChunks.ranges(from: start, to: now) == [DateInterval(start: start, end: now)])
    }

    @Test func anEmptyOrBackwardsRangeHasNoStretches() {
        #expect(HealthImportChunks.ranges(from: now, to: now).isEmpty)
        #expect(HealthImportChunks.ranges(from: now, to: now.addingTimeInterval(-1)).isEmpty)
    }

    @Test func weatherOnlyForRecentRuns() {
        #expect(HealthImportChunks.wantsWeather(now.addingTimeInterval(-86_400), now: now))
        #expect(!HealthImportChunks.wantsWeather(now.addingTimeInterval(-30 * 86_400), now: now))
    }
}
