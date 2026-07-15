import Foundation
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
                let result = WorkoutWeather(
                    temperatureCelsius: hour.temperature.converted(to: UnitTemperature.celsius).value,
                    feelsLikeCelsius: hour.apparentTemperature.converted(to: UnitTemperature.celsius).value,
                    humidityPercent: hour.humidity * 100,
                    windSpeedKmh: hour.wind.speed.converted(to: UnitSpeed.kilometersPerHour).value,
                    conditionSymbol: hour.symbolName,
                    conditionDescription: hour.condition.description
                )
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
            let result = WorkoutWeather(
                temperatureCelsius: hour.temperature.converted(to: UnitTemperature.celsius).value,
                feelsLikeCelsius: hour.apparentTemperature.converted(to: UnitTemperature.celsius).value,
                humidityPercent: hour.humidity * 100,
                windSpeedKmh: hour.wind.speed.converted(to: UnitSpeed.kilometersPerHour).value,
                conditionSymbol: hour.symbolName,
                conditionDescription: hour.condition.description
            )
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
}
