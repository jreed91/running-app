import Foundation

// Beside `ValueTypes.swift` rather than in it: the dew-point maths is `HeatAdaptationPolicy`'s.
extension WorkoutWeather {
    /// The dew point as shown, derived from temperature and humidity when the forecast
    /// carried none — so this never reads as missing data to someone who can see the
    /// humidity right beside it.
    public func dewPointString(unit: UnitPreference) -> String {
        let celsius = HeatAdaptationPolicy.dewPointCelsius(for: self)
        switch unit {
        case .metric:   return String(format: "%.0f°C", celsius)
        case .imperial: return String(format: "%.0f°F", celsius * 9 / 5 + 32)
        }
    }
}
