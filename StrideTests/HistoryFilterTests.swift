import Testing
import Foundation
@testable import Stride

// MARK: - History filtering (U8)
//
// Search shipped in the first UX pass; the date and distance axes are the two questions a
// log that grows forever actually gets asked. The values these produce go straight into a
// fetch predicate, so "no limit" has to mean *no limit* rather than an accidental floor.

struct HistoryFilterTests {

    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A fresh filter narrows nothing")
    func defaultFilterIsInactive() {
        let filter = HistoryFilter()
        #expect(filter.isActive == false)
        #expect(filter.dateRange.earliestDate(now: now, calendar: calendar) == nil)
        #expect(filter.minimumDistance.meters == nil)
        #expect(filter.includesStrengthWorkouts)
    }

    @Test("Either axis on its own makes the filter active")
    func eitherAxisActivates() {
        var byDate = HistoryFilter()
        byDate.dateRange = .month
        #expect(byDate.isActive)

        var byDistance = HistoryFilter()
        byDistance.minimumDistance = .tenK
        #expect(byDistance.isActive)
    }

    @Test("Each range reaches back exactly its own number of days")
    func rangesCountBackFromNow() {
        for range in HistoryFilter.DateRange.allCases {
            guard let days = range.days else {
                #expect(range == .allTime)
                continue
            }
            guard let earliest = range.earliestDate(now: now, calendar: calendar) else {
                Issue.record("\(range) has a day count but produced no date")
                continue
            }
            let elapsedDays = calendar.dateComponents([.day], from: earliest, to: now).day
            #expect(elapsedDays == days)
        }
    }

    @Test("Distance thresholds sit below their nominal race distance")
    func thresholdsAllowForGPSUndercount() {
        // A 5K measured at 4.97 km is still a 5K run, and a filter that hides it is
        // wrong about what the runner did.
        #expect(HistoryFilter.MinimumDistance.fiveK.meters == 4_900)
        #expect(HistoryFilter.MinimumDistance.tenK.meters == 9_800)
        #expect(HistoryFilter.MinimumDistance.halfMarathon.meters == 20_800)
        #expect(HistoryFilter.MinimumDistance.marathon.meters == 41_800)

        // And they ascend, so a longer filter is always a subset of a shorter one.
        let thresholds = HistoryFilter.MinimumDistance.allCases.compactMap(\.meters)
        #expect(thresholds == thresholds.sorted())
    }

    @Test("A distance floor excludes strength sessions, which have no distance")
    func distanceFloorDropsStrength() {
        var filter = HistoryFilter()
        #expect(filter.includesStrengthWorkouts)

        filter.minimumDistance = .fiveK
        #expect(filter.includesStrengthWorkouts == false)

        // A date range alone keeps them: a strength session does have a date.
        filter.minimumDistance = .any
        filter.dateRange = .threeMonths
        #expect(filter.includesStrengthWorkouts)
    }
}
