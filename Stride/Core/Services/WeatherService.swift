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
        guard let weather = try? await WeatherKit.WeatherService.shared.weather(for: location) else {
            return nil
        }

        // Prefer the hourly reading closest to the workout time for accuracy.
        // Falls back to current conditions when the hourly forecast is empty.
        if let hour = weather.hourlyForecast.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }) {
            return WorkoutWeather(
                temperatureCelsius: hour.temperature.converted(to: UnitTemperature.celsius).value,
                feelsLikeCelsius: hour.apparentTemperature.converted(to: UnitTemperature.celsius).value,
                humidityPercent: hour.humidity * 100,
                windSpeedKmh: hour.wind.speed.converted(to: UnitSpeed.kilometersPerHour).value,
                conditionSymbol: hour.symbolName,
                conditionDescription: hour.condition.description
            )
        }

        let c = weather.currentWeather
        return WorkoutWeather(
            temperatureCelsius: c.temperature.converted(to: UnitTemperature.celsius).value,
            feelsLikeCelsius: c.apparentTemperature.converted(to: UnitTemperature.celsius).value,
            humidityPercent: c.humidity * 100,
            windSpeedKmh: c.wind.speed.converted(to: UnitSpeed.kilometersPerHour).value,
            conditionSymbol: c.symbolName,
            conditionDescription: c.condition.description
        )
    }
}
