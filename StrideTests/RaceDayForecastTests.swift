import Testing
import Foundation
@testable import Stride

// MARK: - Race start time + race-day forecast tests (A10)
//
// The stored start time (its round trip, and that it only ever applies to the race it was
// entered for) and the forecast readings picked for the start and the expected finish.

struct RaceDayForecastTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) throws -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return try #require(calendar.date(from: components))
    }

    private func weather(celsius: Double, dewPoint: Double = 5) -> WorkoutWeather {
        WorkoutWeather(
            temperatureCelsius: celsius,
            feelsLikeCelsius: celsius,
            humidityPercent: 50,
            dewPointCelsius: dewPoint,
            windSpeedKmh: 5,
            conditionSymbol: "sun.max.fill",
            conditionDescription: "Clear"
        )
    }

    /// An hourly forecast for the whole of race day, warming a degree an hour from 8 °C at
    /// midnight.
    private func raceDayHours() throws -> [ForecastHour] {
        try (0..<24).map { hour in
            ForecastHour(date: try date(2026, 10, 4, hour), conditions: weather(celsius: 8 + Double(hour)))
        }
    }

    // MARK: RaceStartTime

    @Test("A start time survives its stored form")
    func storageRoundTrip() throws {
        let start = RaceStartTime(
            raceDate: try date(2026, 10, 4),
            time: try date(2000, 1, 1, 7, 30),
            calendar: calendar
        )
        #expect(start.storageValue == "2026-10-04 07:30")
        #expect(RaceStartTime(storageValue: start.storageValue) == start)
    }

    @Test("Empty and malformed stored values read as no start time")
    func malformedStorage() {
        #expect(RaceStartTime(storageValue: "") == nil)
        #expect(RaceStartTime(storageValue: "2026-10-04") == nil)
        #expect(RaceStartTime(storageValue: "2026-13-04 07:30") == nil)
        #expect(RaceStartTime(storageValue: "2026-10-04 25:00") == nil)
    }

    @Test("A start time resolves on its own race day")
    func resolvesOnRaceDay() throws {
        let start = try #require(RaceStartTime(storageValue: "2026-10-04 07:30"))
        let raceDate = try date(2026, 10, 4)
        let expected = try date(2026, 10, 4, 7, 30)
        #expect(start.startDate(forRaceDate: raceDate, calendar: calendar) == expected)
    }

    @Test("A start time entered for one race never applies to another")
    func ignoredForOtherRace() throws {
        let start = try #require(RaceStartTime(storageValue: "2026-10-04 07:30"))
        let nextRace = try date(2026, 10, 11)
        #expect(start.startDate(forRaceDate: nextRace, calendar: calendar) == nil)
    }

    // MARK: Horizon

    @Test("The forecast is asked for only within ten days of the start")
    func horizon() throws {
        let start = try date(2026, 10, 4, 8)
        let tenDaysAndAnHourOut = try date(2026, 9, 24, 7)
        let justUnderTenDaysOut = try date(2026, 9, 24, 9)
        let raceMorning = try date(2026, 10, 4, 6)
        let twoHoursAfterTheGun = try date(2026, 10, 4, 10)
        #expect(RaceDayForecast.isWithinHorizon(start: start, now: tenDaysAndAnHourOut) == false)
        #expect(RaceDayForecast.isWithinHorizon(start: start, now: justUnderTenDaysOut))
        #expect(RaceDayForecast.isWithinHorizon(start: start, now: raceMorning))
        #expect(RaceDayForecast.isWithinHorizon(start: start, now: twoHoursAfterTheGun) == false)
    }

    // MARK: Readings

    @Test("The start reading is the hour nearest the gun")
    func startReading() throws {
        let hours = try raceDayHours()
        let gun = try date(2026, 10, 4, 7, 20)
        let sevenOClock = try date(2026, 10, 4, 7)
        let forecast = try #require(RaceDayForecast.make(from: hours, start: gun, expectedDuration: nil))
        #expect(forecast.start.date == sevenOClock)
        #expect(forecast.finish == nil)
    }

    @Test("The finish reading is the hour nearest the expected finish")
    func finishReading() throws {
        // 07:00 start, 3:30 marathon: finishing about 10:30.
        let hours = try raceDayHours()
        let gun = try date(2026, 10, 4, 7)
        let candidates = [try date(2026, 10, 4, 10), try date(2026, 10, 4, 11)]
        let forecast = try #require(RaceDayForecast.make(from: hours, start: gun, expectedDuration: 3.5 * 3_600))
        let finish = try #require(forecast.finish)
        #expect(candidates.contains(finish.date))
    }

    @Test("A short race that finishes inside the start hour has no separate finish reading")
    func shortRaceHasNoFinishReading() throws {
        let hours = try raceDayHours()
        let gun = try date(2026, 10, 4, 8)
        let forecast = try #require(RaceDayForecast.make(from: hours, start: gun, expectedDuration: 20 * 60))
        #expect(forecast.finish == nil)
    }

    @Test("No forecast near the start means no forecast at all")
    func emptyOrWrongDay() throws {
        let start = try date(2026, 10, 4, 7)
        #expect(RaceDayForecast.make(from: [], start: start, expectedDuration: nil) == nil)
        let dayBefore = try (0..<24).map { hour in
            ForecastHour(date: try date(2026, 10, 3, hour), conditions: weather(celsius: 10))
        }
        #expect(RaceDayForecast.make(from: dayBefore, start: start, expectedDuration: nil) == nil)
    }

    @Test("The heat tier is the worse of start and finish")
    func heatTierIsWorstOfTwo() throws {
        let start = try date(2026, 10, 4, 7)
        let hours = [
            ForecastHour(date: start, conditions: weather(celsius: 10, dewPoint: 5)),
            ForecastHour(date: try date(2026, 10, 4, 11), conditions: weather(celsius: 32, dewPoint: 22)),
        ]

        let forecast = try #require(RaceDayForecast.make(from: hours, start: start, expectedDuration: 4 * 3_600))

        let finishTier = HeatAdaptationPolicy.tier(for: hours[1].conditions)
        #expect(finishTier > HeatAdaptationPolicy.tier(for: hours[0].conditions))
        #expect(forecast.heatTier == finishTier)
    }
}
