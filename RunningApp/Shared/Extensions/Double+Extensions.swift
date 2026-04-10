import Foundation

extension Double {
    // MARK: Pace formatting

    /// Formats seconds-per-km into "M:SS /km", e.g. "5:30 /km".
    var paceString: String {
        guard self > 0 && self.isFinite else { return "--:-- /km" }
        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d /km", minutes, seconds)
    }

    /// Formats seconds-per-km into "M:SS /mi".
    var paceStringImperial: String {
        guard self > 0 && self.isFinite else { return "--:-- /mi" }
        let secsPerMile = self * 1.60934
        let totalSeconds = Int(secsPerMile)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d /mi", minutes, seconds)
    }

    // MARK: Distance formatting

    /// Formats meters as kilometres with one decimal, e.g. "10.5 km".
    var distanceKmString: String {
        String(format: "%.1f km", self / 1000)
    }

    // MARK: Duration formatting

    /// Formats a duration in seconds as "H:MM:SS" or "M:SS".
    var durationString: String {
        guard self > 0 && self.isFinite else { return "0:00" }
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: Unit conversion

    var metersToKm: Double { self / 1000 }
    var kmToMeters: Double { self * 1000 }

    // MARK: Unit-aware formatting

    /// Formats meters as a distance string in the given unit, e.g. "10.5 km" or "6.5 mi".
    func distanceString(unit: UnitPreference) -> String {
        switch unit {
        case .metric:
            return String(format: "%.1f km", self / 1_000)
        case .imperial:
            return String(format: "%.1f mi", self / 1_609.344)
        }
    }

    /// Formats seconds-per-km pace into the given unit, e.g. "5:30 /km" or "8:51 /mi".
    func paceString(unit: UnitPreference) -> String {
        switch unit {
        case .metric: return paceString
        case .imperial: return paceStringImperial
        }
    }

    /// Formats a weekly distance in km into the given unit for display.
    func weeklyDistanceString(unit: UnitPreference) -> String {
        switch unit {
        case .metric:
            return String(format: "%.0f km", self)
        case .imperial:
            return String(format: "%.0f mi", self / 1.60934)
        }
    }
}
