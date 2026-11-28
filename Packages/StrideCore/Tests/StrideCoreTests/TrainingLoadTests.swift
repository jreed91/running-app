import Foundation
import Testing
@testable import StrideCore

/// Covers `TrainingLoad`: per-session TRIMP and the fitness, fatigue and form series.
struct TrainingLoadTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ offset: Int, hour: Int = 7) -> Date {
        let start = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: hour))!
        return calendar.date(byAdding: .day, value: offset, to: start)!
    }

    private func session(
        _ offset: Int,
        minutes: Double = 60,
        heartRate: Double? = nil,
        fallback: Double = 0.6
    ) -> TrainingLoad.Session {
        TrainingLoad.Session(
            id: UUID(),
            date: day(offset),
            durationSeconds: minutes * 60,
            averageHeartRate: heartRate,
            fallbackIntensity: fallback
        )
    }

    // MARK: Per session

    @Test func intensityIsTheHeartRateReserveFraction() {
        let value = TrainingLoad.intensity(averageHeartRate: 148, maxHeartRate: 190, restingHeartRate: 50)
        #expect(abs((value ?? 0) - 0.7) < 0.000_1)
    }

    @Test func intensityIsClamped() {
        #expect(TrainingLoad.intensity(averageHeartRate: 200, maxHeartRate: 190, restingHeartRate: 50) == 1)
        #expect(TrainingLoad.intensity(averageHeartRate: 40, maxHeartRate: 190, restingHeartRate: 50) == 0)
    }

    @Test func noIntensityWithoutHeartRateOrMax() {
        #expect(TrainingLoad.intensity(averageHeartRate: nil, maxHeartRate: 190) == nil)
        #expect(TrainingLoad.intensity(averageHeartRate: 150, maxHeartRate: nil) == nil)
        #expect(TrainingLoad.intensity(averageHeartRate: 150, maxHeartRate: 55, restingHeartRate: 60) == nil)
    }

    @Test func trimpMatchesTheFormula() {
        // 60 min at 0.7: 60 × 0.7 × 0.64 × e^(1.344) ≈ 103.1
        let load = TrainingLoad.load(durationSeconds: 3_600, intensity: 0.7)
        #expect(abs(load - 103.08) < 0.1)
    }

    @Test func hardMinutesCountForMore() {
        let easy = TrainingLoad.load(durationSeconds: 3_600, intensity: 0.6)
        let hard = TrainingLoad.load(durationSeconds: 3_600, intensity: 0.85)
        #expect(hard > easy * 1.7)
    }

    @Test func feelBeatsTheTypeFallback() {
        #expect(TrainingLoad.fallbackIntensity(feel: 4, typeIntensity: 0.6) == 0.8)
        #expect(TrainingLoad.fallbackIntensity(feel: nil, typeIntensity: 0.62) == 0.62)
    }

    @Test func measuredHeartRateBeatsTheFallback() {
        let withHR = session(0, heartRate: 148, fallback: 0.9)
        let load = TrainingLoad.load(of: withHR, maxHeartRate: 190, restingHeartRate: 50)
        #expect(abs(load - TrainingLoad.load(durationSeconds: 3_600, intensity: 0.7)) < 0.000_1)
    }

    // MARK: Series

    @Test func restDaysAreIncluded() {
        let days = TrainingLoad.days(
            for: [session(0), session(3)], maxHeartRate: nil, through: day(5, hour: 20), calendar: calendar
        )
        #expect(days.count == 6)
        #expect(days.map(\.sessionIDs.count) == [1, 0, 0, 1, 0, 0])
    }

    @Test func fatigueRisesFasterThanFitness() {
        let days = TrainingLoad.days(
            for: (0..<5).map { session($0) }, maxHeartRate: nil, through: day(4), calendar: calendar
        )
        let last = days.last!
        #expect(last.fatigue > last.fitness)
        #expect(last.form < 0)
    }

    @Test func restMakesYouFresh() {
        let block = (0..<28).map { session($0) }
        let days = TrainingLoad.days(for: block, maxHeartRate: nil, through: day(40), calendar: calendar)
        let endOfBlock = days[27]
        let afterRest = days.last!
        #expect(endOfBlock.form < afterRest.form)
        #expect(afterRest.form > 0)
        #expect(afterRest.fitness < endOfBlock.fitness)
    }

    @Test func sameDaySessionsAdd() {
        let days = TrainingLoad.days(
            for: [session(0, minutes: 30), session(0, minutes: 30)], maxHeartRate: nil,
            through: day(0), calendar: calendar
        )
        #expect(days.count == 1)
        #expect(abs(days[0].load - TrainingLoad.load(durationSeconds: 3_600, intensity: 0.6)) < 0.000_1)
    }

    @Test func noSessionsNoDays() {
        #expect(TrainingLoad.days(for: [], maxHeartRate: 190, through: day(0), calendar: calendar).isEmpty)
    }

    @Test func formZones() {
        #expect(TrainingLoad.zone(forForm: 12) == .fresh)
        #expect(TrainingLoad.zone(forForm: 0) == .neutral)
        #expect(TrainingLoad.zone(forForm: -20) == .building)
        #expect(TrainingLoad.zone(forForm: -45) == .overreaching)
    }
}
