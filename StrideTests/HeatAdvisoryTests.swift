import Foundation
import Testing
@testable import Stride

/// Covers the plumbing half of weather-tuned workouts (N39): which session gets an
/// advisory, what the forecast has to look like for one to exist, when the banner fires,
/// and how a dismissal behaves when the forecast changes.
///
/// The judgements themselves live in `HeatAdaptationPolicyTests`. Everything here is
/// static and injectable, so none of it needs WeatherKit, a device, or a container.
@MainActor
struct HeatAdvisoryTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .now
    }

    private func conditions(
        temperature: Double,
        feelsLike: Double,
        humidity: Double,
        dewPoint: Double
    ) -> WorkoutWeather {
        WorkoutWeather(
            temperatureCelsius: temperature,
            feelsLikeCelsius: feelsLike,
            humidityPercent: humidity,
            dewPointCelsius: dewPoint,
            windSpeedKmh: 4,
            conditionSymbol: "sun.max.fill",
            conditionDescription: "Clear"
        )
    }

    /// A day that ramps from a cool dawn to a punishing afternoon and back.
    private func forecastDay(_ day: Date) -> [ForecastHour] {
        // swiftlint:disable:next large_tuple
        let shape: [(hour: Int, temperature: Double, feelsLike: Double, dewPoint: Double)] = [
            (5, 17, 17, 14),
            (6, 18, 18, 14),
            (7, 21, 22, 15),
            (10, 27, 29, 17),
            (13, 32, 35, 19),
            (16, 33, 36, 19),
            (19, 27, 28, 18),
            (21, 23, 23, 17)
        ]
        return shape.map { entry in
            ForecastHour(
                date: calendar.date(bySettingHour: entry.hour, minute: 0, second: 0, of: day) ?? day,
                conditions: conditions(
                    temperature: entry.temperature,
                    feelsLike: entry.feelsLike,
                    humidity: 55,
                    dewPoint: entry.dewPoint
                )
            )
        }
    }

    // MARK: - Which hour is read

    @Test("The forecast is read at the hour this runner actually runs")
    func forecastIsReadAtTheUsualHour() {
        let day = date(2027, 7, 14)
        let forecast = forecastDay(day)

        let morning = HeatAdvisoryService.closestHour(to: 7, in: forecast, calendar: calendar)
        let afternoon = HeatAdvisoryService.closestHour(to: 16, in: forecast, calendar: calendar)

        #expect(calendar.component(.hour, from: morning?.date ?? .now) == 7)
        #expect(calendar.component(.hour, from: afternoon?.date ?? .now) == 16)
    }

    @Test("The usual hour is the median of recent runs, not their mean")
    func usualHourIsAMedian() {
        // Nine 07:00 runs and one 22:00 run after a late flight. A mean would drag the
        // forecast into the evening and warn about weather this runner never sees.
        var runs = (0..<9).map { index in
            RunWorkout(
                date: date(2027, 7, 1 + index, 7),
                distanceMeters: 8_000,
                durationSeconds: 2_400,
                workoutType: .easy
            )
        }
        runs.append(RunWorkout(
            date: date(2027, 7, 10, 22),
            distanceMeters: 5_000,
            durationSeconds: 1_500,
            workoutType: .easy
        ))

        #expect(HeatAdvisoryService.typicalRunHour(from: runs, calendar: calendar) == 7)
    }

    @Test("A runner with no history yet gets the conservative default hour")
    func usualHourFallsBack() {
        #expect(HeatAdvisoryService.typicalRunHour(from: [], calendar: calendar) == HeatAdvisoryService.defaultRunHour)
    }

    @Test("Walks are not evidence about when this person runs")
    func walksAreExcludedFromTheUsualHour() {
        let runs = [
            RunWorkout(date: date(2027, 7, 1, 6), distanceMeters: 8_000, durationSeconds: 2_400, workoutType: .easy),
            RunWorkout(date: date(2027, 7, 2, 13), distanceMeters: 2_000, durationSeconds: 1_800, workoutType: .walk),
            RunWorkout(date: date(2027, 7, 3, 13), distanceMeters: 2_000, durationSeconds: 1_800, workoutType: .walk)
        ]
        #expect(HeatAdvisoryService.typicalRunHour(from: runs, calendar: calendar) == 6)
    }

    // MARK: - Whether an advisory exists

    @Test("A hot afternoon tempo produces an advisory")
    func hotAfternoonProducesAdvisory() {
        let day = date(2027, 7, 14)
        let workout = ScheduledWorkout(scheduledDate: day, workoutType: .tempo, targetDistanceMeters: 8_000)

        let advisory = HeatAdvisoryService.advisory(
            for: workout,
            forecast: forecastDay(day),
            plannedHour: 16,
            now: date(2027, 7, 13, 17),
            calendar: calendar
        )

        #expect(advisory != nil)
        #expect(advisory?.workoutID == workout.id)
        #expect((advisory?.tier ?? .none) >= .high)
    }

    @Test("The same day at dawn produces nothing")
    func coolDawnProducesNothing() {
        let day = date(2027, 7, 14)
        let workout = ScheduledWorkout(scheduledDate: day, workoutType: .tempo, targetDistanceMeters: 8_000)

        let advisory = HeatAdvisoryService.advisory(
            for: workout,
            forecast: forecastDay(day),
            plannedHour: 6,
            now: date(2027, 7, 13, 17),
            calendar: calendar
        )

        #expect(advisory == nil)
    }

    @Test("An easy run in the same heat that warns a tempo is left alone")
    func easyRunIsQuieter() {
        let day = date(2027, 7, 14)
        // 10:00 is `.moderate` — enough for a tempo, not for an easy run.
        let forecast = [ForecastHour(
            date: calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day,
            conditions: conditions(temperature: 24, feelsLike: 24, humidity: 55, dewPoint: 16)
        )]

        let easy = ScheduledWorkout(scheduledDate: day, workoutType: .easy)
        let tempo = ScheduledWorkout(scheduledDate: day, workoutType: .tempo)

        let now = date(2027, 7, 13, 17)
        #expect(HeatAdvisoryService.advisory(for: easy, forecast: forecast, plannedHour: 10, now: now, calendar: calendar) == nil)
        #expect(HeatAdvisoryService.advisory(for: tempo, forecast: forecast, plannedHour: 10, now: now, calendar: calendar) != nil)
    }

    @Test("An empty forecast produces no advisory rather than a guess")
    func emptyForecastProducesNothing() {
        let day = date(2027, 7, 14)
        let workout = ScheduledWorkout(scheduledDate: day, workoutType: .tempo)

        #expect(HeatAdvisoryService.advisory(
            for: workout,
            forecast: [],
            plannedHour: 16,
            now: date(2027, 7, 13, 17),
            calendar: calendar
        ) == nil)
    }

    // MARK: - The cooler hour

    @Test("A hot afternoon is offered the cool dawn on the same day")
    func coolerHourIsOffered() {
        let day = date(2027, 7, 14)
        let workout = ScheduledWorkout(scheduledDate: day, workoutType: .tempo)

        let advisory = HeatAdvisoryService.advisory(
            for: workout,
            forecast: forecastDay(day),
            plannedHour: 16,
            now: date(2027, 7, 13, 17),
            calendar: calendar
        )

        let cooler = advisory?.cooler
        #expect(cooler != nil)
        #expect(calendar.component(.hour, from: cooler?.start ?? .now) == 5)
        #expect((cooler?.tier ?? .extreme) < (advisory?.tier ?? .none))
    }

    @Test("A day that is uniformly hot is offered no cooler hour")
    func noCoolerHourOnAFlatDay() {
        let day = date(2027, 7, 14)
        let hot = conditions(temperature: 32, feelsLike: 35, humidity: 55, dewPoint: 21)
        let forecast = [8, 12, 16, 20].map { hour in
            ForecastHour(
                date: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day,
                conditions: hot
            )
        }

        let planned = forecast[2]
        #expect(HeatAdvisoryService.coolerOption(than: planned, in: forecast, calendar: calendar) == nil)
    }

    @Test("The cooler hour is never in the middle of the night")
    func coolerHourStaysInTheWindow() {
        let day = date(2027, 7, 14)
        var forecast = forecastDay(day)
        // 03:00 is the coldest hour of any summer day, and suggesting it would cost more
        // sleep than it saves degrees.
        forecast.append(ForecastHour(
            date: calendar.date(bySettingHour: 3, minute: 0, second: 0, of: day) ?? day,
            conditions: conditions(temperature: 12, feelsLike: 12, humidity: 80, dewPoint: 9)
        ))

        let planned = forecast.first { calendar.component(.hour, from: $0.date) == 16 }
        let cooler = HeatAdvisoryService.coolerOption(than: planned!, in: forecast, calendar: calendar)

        #expect(cooler != nil)
        #expect(calendar.component(.hour, from: cooler?.start ?? .now) != 3)
    }

    // MARK: - When the banner fires

    @Test("The banner is scheduled for six the evening before")
    func bannerFiresTheEveningBefore() {
        let session = date(2027, 7, 14, 7)
        let delivery = NotificationService.heatAdvisoryDelivery(
            for: session,
            now: date(2027, 7, 13, 9),
            calendar: calendar
        )

        #expect(delivery == .scheduled(date(2027, 7, 13, 18)))
    }

    @Test("Opening the app late on the evening before still delivers the warning")
    func lateEveningDeliversImmediately() {
        let session = date(2027, 7, 14, 7)
        let delivery = NotificationService.heatAdvisoryDelivery(
            for: session,
            now: date(2027, 7, 13, 21),
            calendar: calendar
        )

        // Still actionable tonight — an alarm, a treadmill booking, a swapped session.
        #expect(delivery == .immediate)
    }

    @Test("Nothing is sent once the session's own day has begun")
    func morningOfSendsNothing() {
        let session = date(2027, 7, 14, 7)
        let delivery = NotificationService.heatAdvisoryDelivery(
            for: session,
            now: date(2027, 7, 14, 5),
            calendar: calendar
        )

        // A banner the runner can no longer plan around is the thing this feature exists
        // to avoid. The dashboard card is the surface from here on.
        #expect(delivery == .skip)
    }

    @Test("The banner body carries the numbers, not just the verdict")
    func bannerBodyCarriesTheConditions() {
        let advisory = HeatAdvisory(
            workoutID: UUID(),
            workoutType: .tempo,
            scheduledDate: date(2027, 7, 14),
            plannedStart: date(2027, 7, 14, 16),
            conditions: conditions(temperature: 33, feelsLike: 36, humidity: 55, dewPoint: 21),
            tier: .severe,
            cooler: nil,
            generatedAt: date(2027, 7, 13, 17)
        )

        let body = NotificationService.heatAdvisoryBody(advisory, unit: .metric)

        // A warning that says only "it'll be hot" is one the runner has to open the app to
        // act on, which defeats sending it the night before.
        #expect(body.contains("36"))
        #expect(body.contains("21"))
    }

    // MARK: - Storage and dismissal

    @Test("An advisory survives a round trip through storage")
    func advisoryRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "heat-advisory-round-trip"))
        defaults.removePersistentDomain(forName: "heat-advisory-round-trip")

        let advisory = HeatAdvisory(
            workoutID: UUID(),
            workoutType: .longRun,
            scheduledDate: date(2027, 7, 14),
            plannedStart: date(2027, 7, 14, 8),
            conditions: conditions(temperature: 29, feelsLike: 31, humidity: 70, dewPoint: 22),
            tier: .high,
            cooler: nil,
            generatedAt: date(2027, 7, 13, 17)
        )

        HeatAdvisoryStore.save(advisory, in: defaults)
        let restored = HeatAdvisoryStore.current(
            now: date(2027, 7, 13, 18),
            calendar: calendar,
            in: defaults
        )

        #expect(restored == advisory)
    }

    @Test("A stale advisory is cleared on read rather than returned")
    func staleAdvisoryIsDropped() throws {
        let defaults = try #require(UserDefaults(suiteName: "heat-advisory-stale"))
        defaults.removePersistentDomain(forName: "heat-advisory-stale")

        let advisory = HeatAdvisory(
            workoutID: UUID(),
            workoutType: .tempo,
            scheduledDate: date(2027, 7, 14),
            plannedStart: date(2027, 7, 14, 8),
            conditions: conditions(temperature: 29, feelsLike: 31, humidity: 70, dewPoint: 22),
            tier: .high,
            cooler: nil,
            generatedAt: date(2027, 7, 13, 17)
        )
        HeatAdvisoryStore.save(advisory, in: defaults)

        // The session is behind the runner: this is advice about the past.
        #expect(HeatAdvisoryStore.current(now: date(2027, 7, 15, 9), calendar: calendar, in: defaults) == nil)
        // A forecast read a day ago is not the forecast any more, either.
        HeatAdvisoryStore.save(advisory, in: defaults)
        #expect(HeatAdvisoryStore.current(now: date(2027, 7, 14, 6), calendar: calendar, in: defaults) == nil)
    }

    @Test("Answering an advisory silences that severity but not a worse one")
    func dismissalIsKeyedByTier() throws {
        let defaults = try #require(UserDefaults(suiteName: "heat-advisory-dismissal"))
        defaults.removePersistentDomain(forName: "heat-advisory-dismissal")

        let workoutID = UUID()
        func advisory(_ tier: HeatStressTier) -> HeatAdvisory {
            HeatAdvisory(
                workoutID: workoutID,
                workoutType: .tempo,
                scheduledDate: date(2027, 7, 14),
                plannedStart: date(2027, 7, 14, 16),
                conditions: conditions(temperature: 30, feelsLike: 32, humidity: 60, dewPoint: 20),
                tier: tier,
                cooler: nil,
                generatedAt: date(2027, 7, 13, 17)
            )
        }

        HeatAdvisoryStore.markAnswered(advisory(.moderate), in: defaults)

        #expect(HeatAdvisoryStore.isAnswered(advisory(.moderate), in: defaults))
        // Overnight the forecast worsens. That is new information about a materially
        // different day, and a dismissal keyed by session alone would have swallowed it.
        #expect(!HeatAdvisoryStore.isAnswered(advisory(.severe), in: defaults))
    }

    @Test("Clearing everything removes dismissals as well as the advisory")
    func clearAllRemovesDismissals() throws {
        let defaults = try #require(UserDefaults(suiteName: "heat-advisory-clear-all"))
        defaults.removePersistentDomain(forName: "heat-advisory-clear-all")

        let advisory = HeatAdvisory(
            workoutID: UUID(),
            workoutType: .tempo,
            scheduledDate: date(2027, 7, 14),
            plannedStart: date(2027, 7, 14, 16),
            conditions: conditions(temperature: 30, feelsLike: 32, humidity: 60, dewPoint: 20),
            tier: .high,
            cooler: nil,
            generatedAt: date(2027, 7, 13, 17)
        )
        HeatAdvisoryStore.save(advisory, in: defaults)
        HeatAdvisoryStore.markAnswered(advisory, in: defaults)

        HeatAdvisoryStore.clearAll(in: defaults)

        #expect(HeatAdvisoryStore.current(now: date(2027, 7, 13, 18), calendar: calendar, in: defaults) == nil)
        #expect(!HeatAdvisoryStore.isAnswered(advisory, in: defaults))
    }
}
