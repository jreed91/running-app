import Foundation
import Testing
@testable import Stride

/// Covers `ProgressFilter`, the one filter the Progress page follows.
struct ProgressFilterTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func periodsMatchTheOldRangeChips() {
        #expect(ProgressFilter.Period.allCases.map(\.days) == [30, 90, 180, 365, nil])
    }

    @Test func longPeriodsGroupByMonth() {
        #expect(ProgressFilter.Period.sixMonths.grouping == .week)
        #expect(ProgressFilter.Period.year.grouping == .month)
        #expect(ProgressFilter.Period.all.grouping == .month)
    }

    @Test func runTypesSplitTheKinds() {
        let kinds: [ProgressFilter.RunKind] = [.easy, .long, .workout, .race, .other]
        #expect(kinds.filter(ProgressFilter.RunType.all.includes).count == 5)
        #expect(kinds.filter(ProgressFilter.RunType.easyAndLong.includes) == [.easy, .long])
        #expect(kinds.filter(ProgressFilter.RunType.workouts.includes) == [.workout])
        #expect(kinds.filter(ProgressFilter.RunType.races.includes) == [.race])
    }

    @Test func drillCoversItsBarExactly() {
        let buckets = VolumeExplorer.buckets(
            for: [], grouping: .week, from: date(2027, 3, 1), through: date(2027, 3, 17), calendar: calendar
        )
        let picked = ProgressFilter.bucket(at: date(2027, 3, 10), in: buckets)
        let drill = picked.map(ProgressFilter.drill(for:))
        #expect(drill?.start == date(2027, 3, 8, hour: 0))
        #expect(drill?.end == date(2027, 3, 15, hour: 0))
        // Monday midnight is the next week's.
        #expect(ProgressFilter.contains(drill, date(2027, 3, 14, hour: 23)))
        #expect(!ProgressFilter.contains(drill, date(2027, 3, 15, hour: 0)))
    }

    @Test func noDrillContainsEverything() {
        #expect(ProgressFilter.contains(nil, date(2001, 1, 1)))
    }
}
