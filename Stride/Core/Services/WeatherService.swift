import Foundation
import WeatherKit
import CoreLocation

// MARK: - WeatherService

/// Fetches weather conditions for a given location and time using WeatherKit.
/// Results are used to annotate completed ``RunWorkout`` instances with the
/// conditions at run start. All errors are silently swallowed — weather
/// is supplemental data and must never block workout saving.
final class WeatherService: Sendable {

    func fetchWeather(at coordinate: Coordinate, date: Date) async -> WorkoutWeather? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // Prefer hourly conditions at the actual workout time for accuracy.
        // WeatherKit's hourly forecast covers roughly the past 24 h and next 10 days.
        let start = date.addingTimeInterval(-1800)
        let end = date.addingTimeInterval(1800)
        if let hourly = try? await WeatherKit.WeatherService.shared.weather(
            for: location,
            including: .hourlyForecast(startDate: start, endDate: end)
        ), let hour = hourly.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }) {
            return WorkoutWeather(
                temperatureCelsius: hour.temperature.converted(to: .celsius).value,
                feelsLikeCelsius: hour.apparentTemperature.converted(to: .celsius).value,
                humidityPercent: hour.humidity * 100,
                windSpeedKmh: hour.wind.speed.converted(to: .kilometersPerHour).value,
                conditionSymbol: hour.symbolName,
                conditionDescription: hour.condition.description
            )
        }

        // Fall back to current conditions (works for live runs; WeatherKit does not
        // provide historical data for workouts older than the forecast window).
        guard let weather = try? await WeatherKit.WeatherService.shared.weather(for: location) else {
            return nil
        }
        let c = weather.currentWeather
        return WorkoutWeather(
            temperatureCelsius: c.temperature.converted(to: .celsius).value,
            feelsLikeCelsius: c.apparentTemperature.converted(to: .celsius).value,
            humidityPercent: c.humidity * 100,
            windSpeedKmh: c.wind.speed.converted(to: .kilometersPerHour).value,
            conditionSymbol: c.symbolName,
            conditionDescription: c.condition.description
        )
    }
}
