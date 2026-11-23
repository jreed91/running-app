import Foundation
import Testing
@testable import Stride

/// Covers `BestEffortsCache`: each run is worked out once, again only when its series
/// changes, and dropped when it is gone.
struct BestEffortsCacheTests {

    /// A steady run's distance series, a reading every 10 m, encoded as the model stores it.
    private func series(_ meters: Double, secondsPerKm: Double = 300) -> Data {
        let points = stride(from: 0.0, through: meters, by: 10).map {
            SplitBucketing.DistancePoint(elapsedSeconds: $0 / 1_000 * secondsPerKm, cumulativeMeters: $0)
        }
        return (try? JSONEncoder().encode(points)) ?? Data()
    }

    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func worksOutEachRunOnce() async {
        let cache = BestEffortsCache()
        let inputs = [
            BestEffortsCache.Input(id: UUID(), date: day, series: series(5_200)),
            BestEffortsCache.Input(id: UUID(), date: day.addingTimeInterval(86_400), series: series(1_100)),
        ]
        let first = await cache.efforts(for: inputs)
        let second = await cache.efforts(for: inputs)
        #expect(first.count == 2)
        #expect(first == second)
        #expect(await cache.computed == 2)
    }

    @Test func aChangedSeriesIsWorkedOutAgain() async {
        let cache = BestEffortsCache()
        let id = UUID()
        _ = await cache.efforts(for: [.init(id: id, date: day, series: series(1_100))])
        let longer = await cache.efforts(for: [.init(id: id, date: day, series: series(5_200))])
        #expect(await cache.computed == 2)
        #expect(longer.first?.efforts[.fiveK] != nil)
    }

    @Test func aTooShortRunIsRememberedAndNotReturned() async {
        let cache = BestEffortsCache()
        let short = BestEffortsCache.Input(id: UUID(), date: day, series: series(200))
        #expect(await cache.efforts(for: [short]).isEmpty)
        #expect(await cache.efforts(for: [short]).isEmpty)
        #expect(await cache.computed == 1)
    }

    @Test func aRunNoLongerPassedInIsDropped() async {
        let cache = BestEffortsCache()
        let kept = BestEffortsCache.Input(id: UUID(), date: day, series: series(1_100))
        let gone = BestEffortsCache.Input(id: UUID(), date: day, series: series(1_100))
        _ = await cache.efforts(for: [kept, gone])
        #expect(await cache.efforts(for: [kept]).map(\.id) == [kept.id])
        // Passing it back in works it out again, since it was dropped.
        _ = await cache.efforts(for: [kept, gone])
        #expect(await cache.computed == 3)
    }

    @Test func keepsTheOrderGiven() async {
        let cache = BestEffortsCache()
        let ids = (0..<4).map { _ in UUID() }
        let inputs = ids.enumerated().map {
            BestEffortsCache.Input(id: $0.element, date: day.addingTimeInterval(Double($0.offset) * 86_400), series: series(1_100))
        }
        #expect(await cache.efforts(for: inputs).map(\.id) == ids)
        #expect(await cache.efforts(for: inputs.reversed()).map(\.id) == ids.reversed())
    }

    // MARK: By key

    @Test func onlyUnknownRunsAreMissing() async {
        let cache = BestEffortsCache()
        let known = BestEffortsCache.Input(id: UUID(), date: day, series: series(1_100))
        _ = await cache.efforts(for: [known.key], adding: [known])
        let newRun = BestEffortsCache.Key(id: UUID(), date: day)
        let moved = BestEffortsCache.Key(id: known.id, date: day.addingTimeInterval(60))
        #expect(await cache.missing([known.key, newRun]) == [newRun.id])
        #expect(await cache.missing([moved]) == [known.id])
    }

    @Test func askingByKeyNeedsNoSeriesOnceKnown() async {
        let cache = BestEffortsCache()
        let run = BestEffortsCache.Input(id: UUID(), date: day, series: series(5_200))
        _ = await cache.efforts(for: [run.key], adding: [run])
        let again = await cache.efforts(for: [run.key], adding: [])
        #expect(again.first?.efforts[.fiveK] != nil)
        #expect(await cache.computed == 1)
    }

    @Test func keepsEffortsOnDiskBetweenLaunches() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("best-efforts-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let run = BestEffortsCache.Input(id: UUID(), date: day, series: series(5_200))
        _ = await BestEffortsCache(storeURL: url).efforts(for: [run.key], adding: [run])

        let relaunched = BestEffortsCache(storeURL: url)
        #expect(await relaunched.missing([run.key]).isEmpty)
        #expect(await relaunched.efforts(for: [run.key], adding: []).first?.efforts[.fiveK] != nil)
        #expect(await relaunched.computed == 0)
    }
}

