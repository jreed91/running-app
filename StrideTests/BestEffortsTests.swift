import Foundation
import Testing
@testable import Stride

/// Covers `BestEfforts`: the fastest stretch of each distance inside a run, and the
/// records across runs.
struct BestEffortsTests {

    /// A reading every 10 m at a steady `secondsPerKm`, for `meters`.
    private func steady(_ meters: Double, secondsPerKm: Double) -> [BestEfforts.Sample] {
        stride(from: 10.0, through: meters, by: 10).map {
            BestEfforts.Sample(elapsedSeconds: $0 / 1_000 * secondsPerKm, meters: $0)
        }
    }

    /// `first` metres at one pace, then `second` metres at another.
    private func twoPaced(
        _ first: Double, at firstPace: Double,
        _ second: Double, at secondPace: Double
    ) -> [BestEfforts.Sample] {
        let opening = steady(first, secondsPerKm: firstPace)
        let offset = first / 1_000 * firstPace
        let closing = stride(from: 10.0, through: second, by: 10).map {
            BestEfforts.Sample(elapsedSeconds: offset + $0 / 1_000 * secondPace, meters: first + $0)
        }
        return opening + closing
    }

    private func close(_ lhs: Double?, _ rhs: Double, within tolerance: Double = 0.01) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) <= tolerance
    }

    // MARK: One run

    @Test func steadyRunGivesEveryDistanceItCovered() {
        let efforts = BestEfforts.efforts(in: steady(10_500, secondsPerKm: 300))
        #expect(close(efforts[.fourHundred], 120))
        #expect(close(efforts[.oneK], 300))
        #expect(close(efforts[.mile], 482.8032, within: 0.05))
        #expect(close(efforts[.fiveK], 1_500))
        #expect(close(efforts[.tenK], 3_000))
        #expect(efforts[.half] == nil)
    }

    @Test func findsTheFastStretchInsideALongerRun() {
        // 5 km easy at 6:00/km, then 5 km hard at 4:30/km.
        let efforts = BestEfforts.efforts(in: twoPaced(5_000, at: 360, 5_000, at: 270))
        #expect(close(efforts[.fiveK], 1_350))
        #expect(close(efforts[.oneK], 270))
        #expect(close(efforts[.tenK], 3_150))
    }

    @Test func interpolatesBetweenSparseReadings() {
        // Readings only every 300 m; the 1K still lands on 1000 m exactly.
        let samples = stride(from: 300.0, through: 3_000, by: 300).map {
            BestEfforts.Sample(elapsedSeconds: $0 / 1_000 * 300, meters: $0)
        }
        let efforts = BestEfforts.efforts(in: samples)
        #expect(close(efforts[.oneK], 300))
    }

    @Test func aGPSJumpIsNotARecord() {
        // A steady 5:00/km run with a 600 m jump in one second at 2 km.
        var samples = steady(2_000, secondsPerKm: 300)
        samples.append(BestEfforts.Sample(elapsedSeconds: 601, meters: 2_600))
        samples += stride(from: 10.0, through: 1_000, by: 10).map {
            BestEfforts.Sample(elapsedSeconds: 601 + $0 / 1_000 * 300, meters: 2_600 + $0)
        }
        let efforts = BestEfforts.efforts(in: samples)
        // No effort may span the jump: the real 5:00/km pace either side of it stands.
        #expect(close(efforts[.fourHundred], 120))
        #expect(close(efforts[.oneK], 300))
        #expect(efforts[.fiveK] == nil)
    }

    @Test func backwardsReadingsAreIgnored() {
        var samples = steady(1_000, secondsPerKm: 300)
        samples.insert(BestEfforts.Sample(elapsedSeconds: 150, meters: 100), at: 60)
        let efforts = BestEfforts.efforts(in: samples)
        #expect(close(efforts[.oneK], 300))
    }

    @Test func emptyAndShortRunsHaveNoEfforts() {
        #expect(BestEfforts.efforts(in: []).isEmpty)
        #expect(BestEfforts.efforts(in: steady(300, secondsPerKm: 300)).isEmpty)
    }

    // MARK: Across runs

    private let january = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(_ day: Int, fiveK: Double?) -> BestEfforts.RunEfforts {
        BestEfforts.RunEfforts(
            id: UUID(),
            date: january.addingTimeInterval(Double(day) * 86_400),
            efforts: fiveK.map { [.fiveK: $0] } ?? [:]
        )
    }

    @Test func recordIsTheFastest() {
        let runs = [run(1, fiveK: 1_500), run(2, fiveK: 1_420), run(3, fiveK: 1_460), run(4, fiveK: nil)]
        #expect(BestEfforts.records(in: runs)[.fiveK]?.seconds == 1_420)
        #expect(BestEfforts.records(in: runs)[.tenK] == nil)
    }

    @Test func progressionOnlyKeepsNewRecords() {
        let runs = [run(1, fiveK: 1_500), run(2, fiveK: 1_520), run(3, fiveK: 1_460), run(4, fiveK: 1_470),
                    run(5, fiveK: 1_400)]
        #expect(BestEfforts.progression(.fiveK, in: runs).map(\.seconds) == [1_500, 1_460, 1_400])
    }

    @Test func rankCountsFromOne() {
        let slow = run(1, fiveK: 1_500)
        let fast = run(2, fiveK: 1_420)
        let none = run(3, fiveK: nil)
        let runs = [slow, fast, none]
        #expect(BestEfforts.rank(of: fast.id, .fiveK, in: runs) == 1)
        #expect(BestEfforts.rank(of: slow.id, .fiveK, in: runs) == 2)
        #expect(BestEfforts.rank(of: none.id, .fiveK, in: runs) == nil)
    }

    @Test func tiesGoToTheEarlierRun() {
        let first = run(1, fiveK: 1_450)
        let second = run(2, fiveK: 1_450)
        #expect(BestEfforts.ranked(.fiveK, in: [second, first]).first?.runID == first.id)
    }
}
