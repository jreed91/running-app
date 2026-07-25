import Foundation
import Testing
@testable import Stride

/// Covers `PlanRebuildWindow`, the "how long should the replacement block be" maths that
/// ran inline on `AppContainer` (D2). Rebuild is offered to a runner who has fallen
/// behind, so the edge cases — a block that ends today, one that ended last week — are
/// the ordinary ones.
struct PlanRebuildWindowTests {

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        Calendar.current.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        ) ?? .now
    }

    @Test("A span is inclusive of both ends: six days out is one week, seven is two")
    func spanIsInclusive() {
        let start = day(2027, 3, 15)

        #expect(PlanRebuildWindow.remainingWeeks(from: start, to: day(2027, 3, 21)) == 1)
        #expect(PlanRebuildWindow.remainingWeeks(from: start, to: day(2027, 3, 22)) == 2)
    }

    @Test("A partial week is rounded up rather than dropped")
    func partialWeekRoundsUp() {
        let start = day(2027, 3, 15)

        // Ten days left is a week and a half; generating one week would end the plan
        // three days early.
        #expect(PlanRebuildWindow.remainingWeeks(from: start, to: day(2027, 3, 24)) == 2)
    }

    @Test("A whole number of weeks is not rounded up to an extra one")
    func wholeWeeksAreExact() {
        let start = day(2027, 3, 15)

        #expect(PlanRebuildWindow.remainingWeeks(from: start, to: day(2027, 4, 11)) == 4)
    }

    @Test("A block ending today still yields a week — the runner asked for a plan")
    func endingTodayYieldsMinimum() {
        let start = day(2027, 3, 15)

        #expect(PlanRebuildWindow.remainingWeeks(from: start, to: start) == PlanRebuildWindow.minimumWeeks)
    }

    @Test("A block that already ended yields the minimum rather than zero or a negative")
    func expiredBlockYieldsMinimum() {
        let start = day(2027, 3, 15)

        #expect(PlanRebuildWindow.remainingWeeks(from: start, to: day(2027, 3, 1)) == PlanRebuildWindow.minimumWeeks)
    }

    @Test("The span is measured in calendar days, so an end time of day cannot shorten it")
    func timeOfDayDoesNotShortenTheSpan() {
        // A plan ending at 18:00 covers that whole day. Measured as elapsed hours from
        // midnight the span would round down and lose it.
        let start = day(2027, 3, 15)

        #expect(PlanRebuildWindow.remainingWeeks(from: start, to: day(2027, 3, 21, hour: 18)) == 1)
        #expect(PlanRebuildWindow.remainingWeeks(from: start, to: day(2027, 3, 22, hour: 18)) == 2)
    }

    @Test("A start time of day is normalised too, so the caller need not pass midnight")
    func startTimeOfDayIsNormalised() {
        #expect(
            PlanRebuildWindow.remainingWeeks(
                from: day(2027, 3, 15, hour: 21),
                to: day(2027, 3, 21, hour: 6)
            ) == 1
        )
    }
}
