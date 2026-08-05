import Foundation
import SwiftData
import WeatherKit
import CoreLocation

// MARK: - WeatherService

/// Fetches weather conditions for a given location and time using WeatherKit.
/// Results are used to annotate completed ``RunWorkout`` instances with the
/// conditions at run start. All errors are silently swallowed — weather
/// is supplemental data and must never block workout saving.
final class WeatherService: Sendable {

    /// How the weather for a given workout time should be sourced.
    enum FetchStrategy: Equatable, Sendable {
        /// Recent enough that the live forecast's hourly readings cover it.
        case current
        /// Older than the live forecast reaches back — request the historical
        /// hourly range around the workout instead of stamping "now" (H7).
        case historical(start: Date, end: Date)
    }

    /// Live `weather(for:)` only reaches ~24 h into the past, so anything older
    /// must use the historical API or it silently gets *today's* conditions.
    /// A ~6 h margin keeps recent runs on the (cheaper) live path.
    static let historicalThreshold: TimeInterval = 6 * 3600

    /// Pure, testable decision for how to source weather for `date` relative to `now`.
    static func fetchStrategy(for date: Date, now: Date = Date()) -> FetchStrategy {
        guard now.timeIntervalSince(date) > historicalThreshold else { return .current }
        // Query a ±1 h window so the closest-hour pick has readings on both sides.
        return .historical(start: date.addingTimeInterval(-3600),
                           end: date.addingTimeInterval(3600))
    }

    func fetchWeather(at coordinate: Coordinate, date: Date) async -> WorkoutWeather? {
        #if targetEnvironment(simulator)
        AppLogger.log("WeatherKit skipped on simulator — run on device", label: "WeatherKit", level: .debug)
        return nil
        #else

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        AppLogger.log(
            "Requesting weather at (\(String(format: "%.4f", coordinate.latitude)), \(String(format: "%.4f", coordinate.longitude))) for \(date.formatted(.dateTime.month().day().hour().minute()))",
            label: "WeatherKit",
            level: .debug
        )

        let strategy = Self.fetchStrategy(for: date)

        // Historical path: fetch the hourly range around the workout and pick the
        // closest reading. Never fall back to current conditions here — stamping a
        // six-week-old run with today's weather is exactly the bug we're avoiding (H7).
        if case let .historical(start, end) = strategy {
            do {
                let history = try await WeatherKit.WeatherService.shared.weather(
                    for: location,
                    including: .hourly(startDate: start, endDate: end)
                )
                guard let hour = history.min(by: {
                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                }) else {
                    AppLogger.log("No historical weather for past workout — skipping", label: "WeatherKit", level: .debug)
                    return nil
                }
                let result = Self.summary(from: hour)
                AppLogger.log(
                    "Weather (historical): \(result.conditionDescription), \(String(format: "%.0f", result.temperatureCelsius))°C",
                    label: "WeatherKit",
                    level: .info
                )
                return result
            } catch {
                AppLogger.log(
                    "Historical weather request failed: \((error as NSError).localizedDescription) — skipping",
                    label: "WeatherKit",
                    level: .error
                )
                return nil
            }
        }

        let weather: Weather
        do {
            weather = try await WeatherKit.WeatherService.shared.weather(for: location)
        } catch {
            let nsError = error as NSError
            if nsError.domain == "WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors" && nsError.code == 2 {
                let teamID = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? "unknown"
                let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
                AppLogger.log(
                    "WeatherKit JWT auth rejected (Code=2) — bundle=\(bundleID) team=\(teamID) userInfo=\(nsError.userInfo)",
                    label: "WeatherKit",
                    level: .error
                )
            } else {
                AppLogger.log(
                    "WeatherKit request failed: domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)",
                    label: "WeatherKit",
                    level: .error
                )
            }
            return nil
        }

        // Prefer the hourly reading closest to the workout time for accuracy.
        // Falls back to current conditions when the hourly forecast is empty.
        if let hour = weather.hourlyForecast.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }) {
            let result = Self.summary(from: hour)
            AppLogger.log(
                "Weather (hourly): \(result.conditionDescription), \(String(format: "%.0f", result.temperatureCelsius))°C",
                label: "WeatherKit",
                level: .info
            )
            return result
        }

        let c = weather.currentWeather
        let result = WorkoutWeather(
            temperatureCelsius: c.temperature.converted(to: UnitTemperature.celsius).value,
            feelsLikeCelsius: c.apparentTemperature.converted(to: UnitTemperature.celsius).value,
            humidityPercent: c.humidity * 100,
            dewPointCelsius: c.dewPoint.converted(to: UnitTemperature.celsius).value,
            windSpeedKmh: c.wind.speed.converted(to: UnitSpeed.kilometersPerHour).value,
            conditionSymbol: c.symbolName,
            conditionDescription: c.condition.description
        )
        AppLogger.log(
            "Weather (current): \(result.conditionDescription), \(String(format: "%.0f", result.temperatureCelsius))°C",
            label: "WeatherKit",
            level: .info
        )
        return result
        #endif
    }

    #if !targetEnvironment(simulator)
    /// One hourly reading as the app stores it.
    ///
    /// Three call sites built this by hand — the historical path, the live hourly path,
    /// and now the forecast — and the field most likely to be forgotten in a fourth is the
    /// newest one, `dewPoint`, which is the number `HeatAdaptationPolicy` scores on.
    private static func summary(from hour: HourWeather) -> WorkoutWeather {
        WorkoutWeather(
            temperatureCelsius: hour.temperature.converted(to: UnitTemperature.celsius).value,
            feelsLikeCelsius: hour.apparentTemperature.converted(to: UnitTemperature.celsius).value,
            humidityPercent: hour.humidity * 100,
            dewPointCelsius: hour.dewPoint.converted(to: UnitTemperature.celsius).value,
            windSpeedKmh: hour.wind.speed.converted(to: UnitSpeed.kilometersPerHour).value,
            conditionSymbol: hour.symbolName,
            conditionDescription: hour.condition.description
        )
    }
    #endif
}

// MARK: - Forecasting a day the runner has not run yet

/// One hour of a forecast day, as `HeatAdaptationPolicy` consumes it.
struct ForecastHour: Equatable, Sendable {
    let date: Date
    let conditions: WorkoutWeather
}

extension WeatherService {

    /// The hourly forecast across one local day at `coordinate`, earliest first.
    ///
    /// Distinct from `fetchWeather(at:date:)`, which answers "what were the conditions at
    /// this instant" for a run that has already happened. This answers "what is the whole
    /// of this day going to be like", because the advisory has two questions to settle —
    /// how bad the planned hour is, and whether some other hour is materially better —
    /// and asking WeatherKit once for the day is how they stay consistent with each other.
    ///
    /// WeatherKit's hourly forecast reaches about ten days ahead, so the day-before
    /// advisory this exists for is comfortably inside it. Empty on any failure: a forecast
    /// is supplemental in exactly the way a recorded run's weather is, and must never be
    /// the reason a screen fails to load.
    func hourlyForecast(
        at coordinate: Coordinate,
        on day: Date,
        calendar: Calendar = .current
    ) async -> [ForecastHour] {
        #if targetEnvironment(simulator)
        AppLogger.log("WeatherKit forecast skipped on simulator — run on device", label: "WeatherKit", level: .debug)
        return []
        #else
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let hours = try await WeatherKit.WeatherService.shared.weather(
                for: location,
                including: .hourly(startDate: start, endDate: end)
            )
            let forecast = hours
                .map { ForecastHour(date: $0.date, conditions: Self.summary(from: $0)) }
                .sorted { $0.date < $1.date }
            AppLogger.log(
                "Forecast for \(start.formatted(.dateTime.month().day())): \(forecast.count) hourly readings",
                label: "WeatherKit",
                level: .debug
            )
            return forecast
        } catch {
            AppLogger.log(
                "Forecast request failed: \((error as NSError).localizedDescription) — skipping",
                label: "WeatherKit",
                level: .error
            )
            return []
        }
        #endif
    }
}

// MARK: - Attaching weather to a run

extension WeatherService {

    /// Fetches the conditions at a run's start and stores them on the run.
    ///
    /// One definition for both callers (N27): `AppContainer` used for the app's own
    /// finish path and `WorkoutSyncService` for imports carried byte-identical copies
    /// of this, so a change to logging or save behaviour only ever landed in one of
    /// them. No-ops silently when WeatherKit has nothing — weather is supplemental and
    /// must never block a run being saved.
    @MainActor
    func attach(to workout: RunWorkout, coordinate: Coordinate, context: ModelContext) async {
        AppLogger.log(
            "Attaching weather to workout \(workout.id) at "
                + "(\(String(format: "%.4f", coordinate.latitude)), \(String(format: "%.4f", coordinate.longitude)))",
            label: "WeatherKit",
            level: .debug
        )
        guard let summary = await fetchWeather(at: coordinate, date: workout.date) else {
            AppLogger.log(
                "Weather fetch returned nil for workout \(workout.id) — skipping attach",
                label: "WeatherKit",
                level: .warning
            )
            return
        }
        workout.weather = summary
        context.saveOrLog("the run's weather snapshot")
        AppLogger.log("Weather attached to workout \(workout.id)", label: "WeatherKit", level: .info)
    }
}
