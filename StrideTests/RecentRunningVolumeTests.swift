import Foundation
import Testing
@testable import Stride

struct RecentRunningVolumeTests {

    private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

    private func run(daysAgo: Double, km: Double) -> RecentRunningVolume.Run {
        .init(date: now.addingTimeInterval(-daysAgo * 86_400), meters: km * 1_000)
    }

    @Test("No runs in the last six months means there is nothing to go on")
    func noRunsIsNil() {
        #expect(RecentRunningVolume(runs: [], now: now) == nil)
        #expect(RecentRunningVolume(runs: [run(daysAgo: 200, km: 10)], now: now) == nil)
    }

    @Test("The weekly average is over the last four weeks only")
    func averagesLastFourWeeks() throws {
        let volume = try #require(RecentRunningVolume(runs: [
            run(daysAgo: 2, km: 5), run(daysAgo: 9, km: 5), run(daysAgo: 16, km: 6),
            run(daysAgo: 60, km: 20),   // before the break: evidence, not volume
        ], now: now))
        #expect(abs(volume.averageWeeklyKm - 4) < 1e-9)
        #expect(abs(volume.longestRunKm - 6) < 1e-9)
    }

    @Test("Someone who ran before a break but not since starts at the floor")
    func breakStartsAtFloor() throws {
        let volume = try #require(RecentRunningVolume(runs: [run(daysAgo: 50, km: 12)], now: now))
        #expect(volume.averageWeeklyKm == 0)
        #expect(volume.startingKm == RecentRunningVolume.floorKm)
    }

    @Test("Week one is the recent average plus 10%, and each week grows 10% on the last")
    func ceilingGrows() {
        let volume = RecentRunningVolume(averageWeeklyKm: 20, longestRunKm: 8)
        #expect(abs(volume.ceilingKm(weekIndex: 0) - 22) < 1e-9)
        #expect(abs(volume.ceilingKm(weekIndex: 1) - 24.2) < 1e-9)
        #expect(abs(volume.ceilingKm(weekIndex: 2) - 26.62) < 1e-9)
    }

    @Test("The long run's ceiling starts 10% over the longest recent run, never under 5 km")
    func longRunCeiling() {
        let volume = RecentRunningVolume(averageWeeklyKm: 20, longestRunKm: 8)
        #expect(abs(volume.longRunCeilingKm(weekIndex: 0) - 8.8) < 1e-9)
        #expect(abs(volume.longRunCeilingKm(weekIndex: 1) - 9.68) < 1e-9)
        let shortRunsOnly = RecentRunningVolume(averageWeeklyKm: 6, longestRunKm: 2)
        #expect(shortRunsOnly.longRunCeilingKm(weekIndex: 0) == RecentRunningVolume.longRunFloorKm)
    }

    @Test("Runs in the future or of no distance are ignored")
    func ignoresJunk() {
        #expect(RecentRunningVolume(runs: [run(daysAgo: -3, km: 10), run(daysAgo: 3, km: 0)], now: now) == nil)
    }
}
