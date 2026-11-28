import Foundation

extension Double {
    // MARK: Pace formatting

    /// Formats seconds-per-km into "M:SS min/km", e.g. "5:30 min/km".
    var paceString: String {
        guard self > 0 && self.isFinite else { return "--:-- min/km" }
        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d min/km", minutes, seconds)
    }

    /// Formats seconds-per-km into "M:SS min/mi".
    var paceStringImperial: String {
        guard self > 0 && self.isFinite else { return "--:-- min/mi" }
        let secsPerMile = self * 1.60934
        let totalSeconds = Int(secsPerMile)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d min/mi", minutes, seconds)
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

    /// Formats a value already in kilometres as a distance string in the given unit.
    func distanceStringFromKm(unit: UnitPreference) -> String {
        (self * 1_000).distanceString(unit: unit)
    }

    /// Converts metres to the user's preferred distance unit (kilometres or miles).
    ///
    /// The numeric sibling of ``distanceString(unit:)``, for chart values that are
    /// plotted rather than printed — the same split ``elevationValue(unit:)`` makes.
    func distanceValue(unit: UnitPreference) -> Double {
        switch unit {
        case .metric:   return self / 1_000
        case .imperial: return self / 1_609.344
        }
    }

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

    /// Formats seconds-per-km as a bare "M:SS" in the given unit, with no unit label.
    /// For compact metric cells that carry their own label.
    func paceValueString(unit: UnitPreference) -> String {
        guard self > 0, isFinite else { return "--:--" }
        let perUnit = unit == .metric ? self : self * 1.60934
        let total = Int(perUnit)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Converts a seconds-per-kilometre figure into seconds per the display unit, for
    /// comparing or differencing paces without formatting them. Uses the same factor as
    /// ``paceStringImperial`` so a delta always agrees with the paces shown beside it.
    func paceSecondsValue(unit: UnitPreference) -> Double {
        unit == .metric ? self : self * 1.60934
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

    // MARK: Elevation formatting

    /// Converts metres to the user's preferred elevation unit (metres or feet).
    func elevationValue(unit: UnitPreference) -> Double {
        unit == .metric ? self : self * 3.28084
    }

    /// Formats metres as an elevation string including the unit label, e.g. "42 m" or "138 ft".
    func elevationString(unit: UnitPreference) -> String {
        switch unit {
        case .metric:   return String(format: "%.0f m", self)
        case .imperial: return String(format: "%.0f ft", self * 3.28084)
        }
    }
}
