import Foundation
import Testing
@testable import Stride

/// Covers `YearRecapCards`: which recap cards appear, in what order, and what they say.
/// These strings go out on shared images, so each one is pinned here.
@MainActor
struct YearRecapCardsTests {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func run(
        on date: Date,
        meters: Double = 8_000,
        seconds: Double = 2_880,
        type: WorkoutType = .easy
    ) -> RunWorkout {
        RunWorkout(date: date, distanceMeters: meters, durationSeconds: seconds, workoutType: type)
    }

    private func cards(
        _ runs: [RunWorkout],
        now: Date? = nil,
        unit: UnitPreference = .metric
    ) -> [YearRecapCard] {
        let year = YearInRunning.make(from: runs, year: 2026, now: now ?? day(2026, 12, 15), calendar: calendar)
        return YearRecapCards.make(from: year, unit: unit, calendar: calendar)
    }

    private var easyYear: [RunWorkout] {
        [
            run(on: day(2026, 1, 10, hour: 6)),
            run(on: day(2026, 3, 10, hour: 6), meters: 16_000, seconds: 5_760),
            run(on: day(2026, 3, 11, hour: 7)),
            run(on: day(2026, 6, 1, hour: 18)),
        ]
    }

    // MARK: Which cards

    @Test("Too few runs gives no cards, so the screen shows its empty state")
    func tooFewRuns() {
        #expect(cards([run(on: day(2026, 1, 1)), run(on: day(2026, 1, 2))]).isEmpty)
    }

    @Test("Cards open on the cover and close on the outro, skipping empty ones")
    func orderAndSkips() {
        let kinds = cards(easyYear).map(\.kind)

        // No run near a race distance, and no quality sessions: no best efforts, no fitness.
        #expect(kinds == [.cover, .distance, .consistency, .months, .longestRun, .outro])
    }

    @Test("Best efforts appear when a run was about a race distance, with a PB count")
    func bestEffortsCard() {
        let runs = easyYear + [run(on: day(2026, 5, 1), meters: 5_000, seconds: 1_500, type: .race)]

        let card = cards(runs).first { $0.kind == .bestEfforts }

        #expect(card?.headline == "1 personal best")
        #expect(card?.efforts.first?.distance == "5K")
        #expect(card?.efforts.first?.time == "25:00")
        #expect(card?.efforts.first?.date == "May 1")
        #expect(card?.efforts.first?.isPersonalBest == true)
    }

    @Test("Fitness gets a card only when it rose")
    func fitnessOnlyWhenUp() {
        let faster = (1...6).map { month in
            run(on: day(2026, month, 2), meters: 5_000, seconds: Double(1_700 - month * 30), type: .tempo)
        }
        let slower = (1...6).map { month in
            run(on: day(2026, month, 2), meters: 5_000, seconds: Double(1_400 + month * 30), type: .tempo)
        }

        let up = cards(easyYear + faster).first { $0.kind == .fitness }
        #expect(up != nil)
        #expect(up?.headline.hasPrefix("+") == true)

        #expect(!cards(easyYear + slower).contains { $0.kind == .fitness })
    }

    // MARK: Wording

    @Test("The year says 'so far' until it ends")
    func soFarWording() {
        let during = cards(easyYear)
        #expect(during.first { $0.kind == .distance }?.eyebrow == "2026 SO FAR")
        #expect(during.first?.caption == "My year in running, so far")

        let after = cards(easyYear, now: day(2027, 1, 2))
        #expect(after.first { $0.kind == .distance }?.eyebrow == "2026")
        #expect(after.first?.caption == "My year in running")
    }

    @Test("Distance card shows the total without decimals and the change on last year")
    func distanceCard() {
        let runs = easyYear + [run(on: day(2025, 6, 1), meters: 32_000)]

        let card = cards(runs).first { $0.kind == .distance }

        #expect(card?.headline == "40 km")
        #expect(card?.caption == "25% further than 2025.")
        #expect(card?.stats.first?.value == "4")
    }

    @Test("Distance card has an encouraging line with no previous year")
    func distanceCardNoPreviousYear() {
        #expect(cards(easyYear).first { $0.kind == .distance }?.caption == "Every one of them counted.")
    }

    @Test("Consistency card names the usual time of day with the right article")
    func consistencyCaption() {
        let card = cards(easyYear).first { $0.kind == .consistency }

        #expect(card?.headline == "4 days")
        #expect(card?.caption == "Days I ran. Mostly an early-morning runner.")
        #expect(card?.stats.first?.value == "2 days")
    }

    @Test("Month bars scale to the biggest month and name it")
    func monthBars() {
        let card = cards(easyYear).first { $0.kind == .months }

        #expect(card?.headline == "March")
        #expect(card?.months.count == 12)
        #expect(card?.months[2].height == 1)
        #expect(card?.months[2].isBiggest == true)
        #expect(card?.months[0].label == "J")
        #expect(card?.months[1].height == 0)
    }

    @Test("Longest run card shows its distance, date and pace")
    func longestRun() {
        let card = cards(easyYear).first { $0.kind == .longestRun }

        #expect(card?.headline == "16.0 km")
        #expect(card?.caption == "My longest run, on March 10.")
        #expect(card?.stats.first?.value == "1:36:00")
    }

    // MARK: Formatting helpers

    @Test("Previous-year line for more, less and the same")
    func previousYearLine() {
        func line(this: Double, last: Double) -> String? {
            let runs = [
                run(on: day(2026, 2, 1), meters: this),
                run(on: day(2026, 2, 2), meters: 1),
                run(on: day(2026, 2, 3), meters: 1),
                run(on: day(2025, 2, 1), meters: last),
            ]
            let year = YearInRunning.make(from: runs, year: 2026, now: day(2026, 12, 1), calendar: calendar)
            return YearRecapCards.previousYearLine(year)
        }

        #expect(line(this: 9_998, last: 5_000) == "100% further than 2025.")
        #expect(line(this: 3_998, last: 5_000) == "20% less than 2025, and still out there.")
        #expect(line(this: 4_998, last: 5_000) == "About the same as 2025.")
    }

    @Test("Hours and days read naturally")
    func hoursAndDays() {
        #expect(YearRecapCards.hoursString(3_600) == "1 hour")
        #expect(YearRecapCards.hoursString(10 * 3_600 + 1_799) == "10 hours")
        #expect(YearRecapCards.hoursString(45 * 60) == "45 minutes")
        #expect(YearRecapCards.days(1) == "1 day")
        #expect(YearRecapCards.days(3) == "3 days")
    }

    @Test("Imperial totals are whole miles and feet")
    func imperial() {
        #expect(YearRecapCards.wholeDistance(16_093.44, unit: .imperial) == "10 mi")
        #expect(YearRecapCards.wholeElevation(100, unit: .imperial) == "328 ft")
    }
}
