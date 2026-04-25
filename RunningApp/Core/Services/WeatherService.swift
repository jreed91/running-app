import Foundation
import WeatherKit
import CoreLocation

// MARK: - WeatherService

/// Fetches current weather conditions for a given location using WeatherKit.
/// Results are used to annotate completed ``RunWorkout`` instances with the
/// conditions at run start. All errors are silently swallowed — weather
/// is supplemental data and must never block workout saving.
final class WeatherService: Sendable {

    func fetchWeather(at coordinate: Coordinate, date: Date) async -> WorkoutWeather? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
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
