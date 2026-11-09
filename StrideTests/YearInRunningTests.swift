import Foundation
import Testing
@testable import Stride

/// Covers `YearInRunning`, the numbers behind the year-in-running recap. Every figure here
/// can end up on a shared image, so a wrong one is wrong in public.
///
/// Pins a UTC calendar so year and day boundaries don't move with the test machine.
@MainActor
struct YearInRunningTests {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Mid-December 2026: the recap is read before the year ends.
    private var december: Date { day(2026, 12, 15) }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func run(
        on date: Date,
        meters: Double = 5_000,
        seconds: Double = 1_800,
        type: WorkoutType = .easy,
        elevation: Double? = nil
    ) -> RunWorkout {
        let workout = RunWorkout(date: date, distanceMeters: meters, durationSeconds: seconds, workoutType: type)
        workout.elevationGainMeters = elevation
        return workout
    }

    private func recap(_ runs: [RunWorkout], year: Int = 2026, now: Date? = nil) -> YearInRunning {
        YearInRunning.make(from: runs, year: year, now: now ?? december, calendar: calendar)
    }

    // MARK: Totals

    @Test("Totals count only this year's runs")
    func totalsCountOnlyTheYear() {
        let runs = [
            run(on: day(2026, 1, 3), meters: 5_000, seconds: 1_500),
            run(on: day(2026, 6, 10), meters: 10_000, seconds: 3_000),
            run(on: day(2025, 12, 31), meters: 8_000, seconds: 2_400),
            run(on: day(2027, 1, 1), meters: 8_000, seconds: 2_400),
        ]

        let year = recap(runs)

        #expect(year.runCount == 2)
        #expect(year.totalMeters == 15_000)
        #expect(year.totalSeconds == 4_500)
        #expect(year.averagePaceSecondsPerKm == 300)
    }

    @Test("Walks and cross-training are not part of the running year")
    func walksAreLeftOut() {
        let runs = [
            run(on: day(2026, 3, 1)),
            run(on: day(2026, 3, 2), meters: 6_000, type: .walk),
            run(on: day(2026, 3, 3), meters: 20_000, type: .crossTraining),
        ]

        let year = recap(runs)

        #expect(year.runCount == 1)
        #expect(year.totalMeters == 5_000)
    }

    @Test("A run late on 31 December belongs to the year in the calendar's time zone")
    func yearBoundaryFollowsCalendar() {
        let lateNewYearsEve = day(2026, 12, 31, hour: 23)
        #expect(recap([run(on: lateNewYearsEve)]).runCount == 1)
        #expect(recap([run(on: lateNewYearsEve)], year: 2027, now: day(2027, 2, 1)).runCount == 0)
    }

    @Test("Elevation is nil when no run recorded any, not zero")
    func elevationNilWithoutData() {
        let none = recap([run(on: day(2026, 2, 1)), run(on: day(2026, 2, 2), elevation: 0)])
        #expect(none.elevationGainMeters == nil)

        let some = recap([run(on: day(2026, 2, 1), elevation: 40), run(on: day(2026, 2, 2), elevation: 60)])
        #expect(some.elevationGainMeters == 100)
    }

    @Test("Active days count each day once")
    func activeDaysCountDistinctDays() {
        let runs = [
            run(on: day(2026, 4, 1, hour: 7)),
            run(on: day(2026, 4, 1, hour: 18)),
            run(on: day(2026, 4, 3)),
        ]
        #expect(recap(runs).activeDays == 2)
    }

    // MARK: Streak

    @Test("Longest streak is consecutive days inside the year")
    func longestStreak() {
        let runs = [
            day(2026, 5, 1), day(2026, 5, 2), day(2026, 5, 3),
            day(2026, 5, 10), day(2026, 5, 11),
        ].map { run(on: $0) }
        #expect(recap(runs).longestStreakDays == 3)
    }

    @Test("A streak from the previous December only counts its days in this year")
    func streakDoesNotReachIntoLastYear() {
        let runs = [
            day(2025, 12, 30), day(2025, 12, 31), day(2026, 1, 1), day(2026, 1, 2),
        ].map { run(on: $0) }
        #expect(recap(runs).longestStreakDays == 2)
    }

    // MARK: Months

    @Test("Monthly distance has twelve entries and names the biggest month")
    func monthlyDistances() {
        let runs = [
            run(on: day(2026, 1, 5), meters: 5_000),
            run(on: day(2026, 3, 5), meters: 12_000),
            run(on: day(2026, 3, 9), meters: 4_000),
            run(on: day(2026, 7, 5), meters: 15_000),
        ]

        let year = recap(runs)

        #expect(year.monthlyMeters.count == 12)
        #expect(year.monthlyMeters[0] == 5_000)
        #expect(year.monthlyMeters[2] == 16_000)
        #expect(year.biggestMonth == 3)
    }

    @Test("No runs means no biggest month and no longest run")
    func emptyYear() {
        let year = recap([])

        #expect(year.runCount == 0)
        #expect(year.biggestMonth == nil)
        #expect(year.longestRun == nil)
        #expect(year.averagePaceSecondsPerKm == nil)
        #expect(year.monthlyMeters == Array(repeating: 0, count: 12))
        #expect(!year.hasEnoughForRecap)
    }

    // MARK: Longest run

    @Test("Longest run is the furthest, earliest on a tie")
    func longestRun() {
        let first = run(on: day(2026, 2, 1), meters: 21_100)
        let tie = run(on: day(2026, 9, 1), meters: 21_100)
        let shorter = run(on: day(2026, 5, 1), meters: 18_000)

        let year = recap([tie, shorter, first])

        #expect(year.longestRun?.runID == first.id)
        #expect(year.longestRun?.meters == 21_100)
    }

    // MARK: Best efforts

    @Test("A best effort must be about the race distance, not a longer run")
    func bestEffortIgnoresLongerRuns() {
        // A fast 10 km run must not appear as the 5K.
        let tenK = run(on: day(2026, 4, 1), meters: 10_000, seconds: 2_400)
        let fiveK = run(on: day(2026, 4, 8), meters: 5_050, seconds: 1_500)

        let efforts = recap([tenK, fiveK]).bestEfforts

        let five = efforts.first { $0.distance == .fiveK }
        #expect(five?.run.runID == fiveK.id)
        let ten = efforts.first { $0.distance == .tenK }
        #expect(ten?.run.runID == tenK.id)
        #expect(!efforts.contains { $0.distance == .half })
    }

    @Test("A run just short of the distance from GPS noise still counts")
    func bestEffortAllowsGPSNoise() {
        let slightlyShort = run(on: day(2026, 4, 1), meters: 4_920, seconds: 1_400)
        let tooShort = run(on: day(2026, 4, 2), meters: 4_800, seconds: 1_200)

        let five = recap([slightlyShort, tooShort]).bestEfforts.first { $0.distance == .fiveK }

        #expect(five?.run.runID == slightlyShort.id)
    }

    @Test("The fastest 5K of the year is ranked by pace")
    func bestEffortRanksByPace() {
        let slower = run(on: day(2026, 3, 1), meters: 5_000, seconds: 1_600)
        let faster = run(on: day(2026, 8, 1), meters: 5_200, seconds: 1_560)

        let five = recap([slower, faster]).bestEfforts.first { $0.distance == .fiveK }

        #expect(five?.run.runID == faster.id)
    }

    @Test("A best effort is a personal best only if faster than every earlier year")
    func personalBestAgainstEarlierYears() {
        let lastYear = run(on: day(2025, 5, 1), meters: 5_000, seconds: 1_400)
        let thisYearFiveK = run(on: day(2026, 5, 1), meters: 5_000, seconds: 1_500)
        let thisYearTenK = run(on: day(2026, 6, 1), meters: 10_000, seconds: 3_000)

        let efforts = recap([lastYear, thisYearFiveK, thisYearTenK]).bestEfforts

        #expect(efforts.first { $0.distance == .fiveK }?.isPersonalBest == false)
        // Nothing earlier at 10K, so this year's is a best.
        #expect(efforts.first { $0.distance == .tenK }?.isPersonalBest == true)
    }

    @Test("A later year's faster run doesn't take away this year's personal best")
    func personalBestIgnoresLaterYears() {
        let thisYear = run(on: day(2026, 5, 1), meters: 5_000, seconds: 1_500)
        let nextYear = run(on: day(2027, 5, 1), meters: 5_000, seconds: 1_300)

        let five = recap([thisYear, nextYear], now: day(2027, 6, 1)).bestEfforts.first { $0.distance == .fiveK }

        #expect(five?.isPersonalBest == true)
    }

    // MARK: Fitness

    @Test("Fitness change needs enough quality efforts")
    func fitnessNeedsSamples() {
        let few = (1...5).map { run(on: day(2026, $0, 1), type: .tempo) }
        #expect(recap(few).fitnessChange == nil)
    }

    @Test("Fitness change compares early and late quality efforts")
    func fitnessCompareEnds() {
        // Same 5 km, getting faster through the year.
        let runs = (1...6).map { month in
            run(on: day(2026, month, 1), meters: 5_000, seconds: Double(1_700 - month * 30), type: .tempo)
        }

        let change = recap(runs).fitnessChange

        #expect(change != nil)
        #expect((change?.delta ?? 0) > 0)
    }

    // MARK: Time of day

    @Test("Usual time of day needs a clear majority")
    func usualTimeOfDay() {
        let mornings = [
            run(on: day(2026, 1, 1, hour: 6)),
            run(on: day(2026, 1, 2, hour: 6)),
            run(on: day(2026, 1, 3, hour: 7)),
            run(on: day(2026, 1, 4, hour: 18)),
        ]
        #expect(recap(mornings).usualTimeOfDay == .earlyMorning)

        let split = [
            run(on: day(2026, 1, 1, hour: 6)),
            run(on: day(2026, 1, 2, hour: 6)),
            run(on: day(2026, 1, 3, hour: 18)),
            run(on: day(2026, 1, 4, hour: 18)),
        ]
        #expect(recap(split).usualTimeOfDay == nil)
    }

    // MARK: Comparison and state

    @Test("Previous year is nil with no runs then, and the change is a fraction")
    func previousYear() {
        let newRunner = recap([run(on: day(2026, 3, 1))])
        #expect(newRunner.previousYearMeters == nil)
        #expect(newRunner.changeFromPreviousYear == nil)

        let runs = [
            run(on: day(2025, 3, 1), meters: 10_000),
            run(on: day(2026, 3, 1), meters: 10_000),
            run(on: day(2026, 3, 2), meters: 2_500),
        ]
        #expect(recap(runs).changeFromPreviousYear == 0.25)
    }

    @Test("The year is in progress until 1 January")
    func inProgress() {
        #expect(recap([], now: day(2026, 12, 31, hour: 23)).isInProgress)
        #expect(!recap([], now: day(2027, 1, 1, hour: 0)).isInProgress)
    }

    @Test("A recap needs at least three runs")
    func enoughForRecap() {
        let two = [run(on: day(2026, 1, 1)), run(on: day(2026, 1, 2))]
        #expect(!recap(two).hasEnoughForRecap)
        #expect(recap(two + [run(on: day(2026, 1, 3))]).hasEnoughForRecap)
    }
}
