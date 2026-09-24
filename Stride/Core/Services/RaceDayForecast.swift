import Foundation

// MARK: - RaceStartTime

/// When the gun goes on race day, as the runner entered it (A10).
///
/// The app stores a race *date* on the profile and the plan, and nothing about the hour.
/// That was enough for a countdown and a taper, and it is the reason race-day weather was
/// deferred when the hub shipped: a forecast is for an hour, and choosing one would have
/// meant inventing the start.
///
/// Stored as a string in `AppSettings` (synced through iCloud key-value storage) rather than
/// as a property on `UserProfile` or `TrainingPlan`: a new stored property on a `@Model` is a
/// CloudKit schema deployment, and this is one small value. It carries its own race day so a
/// start time entered for one race is never applied to the next — change the race date and
/// the old time simply stops matching, and the hub asks again.
struct RaceStartTime: Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int

    /// The start on `raceDate`'s day at the time of day in `time`, both read in `calendar`.
    init(raceDate: Date, time: Date, calendar: Calendar = .current) {
        let dayParts = calendar.dateComponents([.year, .month, .day], from: raceDate)
        let timeParts = calendar.dateComponents([.hour, .minute], from: time)
        self.year = dayParts.year ?? 0
        self.month = dayParts.month ?? 0
        self.day = dayParts.day ?? 0
        self.hour = timeParts.hour ?? 0
        self.minute = timeParts.minute ?? 0
    }

    /// Parses the stored form, `yyyy-MM-dd HH:mm`. Nil for the empty string ("no start time
    /// set") and for anything malformed, which is treated the same way.
    init?(storageValue: String) {
        let parts = storageValue.split { $0 == "-" || $0 == " " || $0 == ":" }
            .compactMap { Int($0) }
        guard parts.count == 5,
              (1...12).contains(parts[1]),
              (1...31).contains(parts[2]),
              (0...23).contains(parts[3]),
              (0...59).contains(parts[4]) else { return nil }
        self.year = parts[0]
        self.month = parts[1]
        self.day = parts[2]
        self.hour = parts[3]
        self.minute = parts[4]
    }

    /// The form `AppSettings.raceStartTimeValue` stores. Local wall-clock time with no zone,
    /// on purpose: a 7:30 start is 7:30 wherever the phone is when the hub is opened.
    var storageValue: String {
        String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
    }

    /// The start as an instant, when this start time belongs to `raceDate`'s day, or nil
    /// when it was entered for a different race.
    func startDate(forRaceDate raceDate: Date, calendar: Calendar = .current) -> Date? {
        let race = calendar.dateComponents([.year, .month, .day], from: raceDate)
        guard race.year == year, race.month == month, race.day == day else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }
}

// MARK: - RaceDayForecast

/// The weather the runner will race in: at the start, and at the time they expect to finish.
///
/// Two readings rather than one because a marathon that starts at 7 a.m. finishes in the
/// late morning, and a start at 12 °C that finishes at 22 °C is the race the runner needs
/// to hear about. The heat tier is the worse of the two, through the same
/// `HeatAdaptationPolicy.tier` the evening-before advisory uses, so the hub and the
/// training advisories never disagree about what counts as hot.
struct RaceDayForecast: Equatable, Sendable {
    let start: ForecastHour
    /// The reading nearest the expected finish, when there is a finish time to aim at and
    /// it falls in a different hour from the start.
    let finish: ForecastHour?
    let heatTier: HeatStressTier

    /// WeatherKit's hourly forecast reaches about ten days ahead (see
    /// `WeatherService.hourlyForecast`). Further out, the hub says when the forecast will
    /// arrive instead of asking for one that cannot come back.
    static let horizonDays = 10

    /// Whether a forecast can exist yet for a race starting at `start`.
    static func isWithinHorizon(start: Date, now: Date) -> Bool {
        let interval = start.timeIntervalSince(now)
        return interval > -3_600 && interval <= Double(horizonDays) * 86_400
    }

    /// The readings for a race starting at `start` and expected to take `expectedDuration`
    /// seconds, from a day's hourly forecast. Nil when the forecast has nothing within an
    /// hour of the start — an empty or failed fetch, or a forecast for the wrong day.
    static func make(
        from hours: [ForecastHour],
        start: Date,
        expectedDuration: TimeInterval?
    ) -> RaceDayForecast? {
        guard let startHour = nearest(to: start, in: hours) else { return nil }

        var finishHour: ForecastHour?
        if let expectedDuration, expectedDuration > 0,
           let candidate = nearest(to: start.addingTimeInterval(expectedDuration), in: hours),
           candidate.date != startHour.date {
            finishHour = candidate
        }

        let tiers = [startHour, finishHour].compactMap { $0 }
            .map { HeatAdaptationPolicy.tier(for: $0.conditions) }
        return RaceDayForecast(
            start: startHour,
            finish: finishHour,
            heatTier: tiers.max() ?? .none
        )
    }

    /// The reading closest to `date`, if one is within the hour either side of it.
    private static func nearest(to date: Date, in hours: [ForecastHour]) -> ForecastHour? {
        hours
            .filter { abs($0.date.timeIntervalSince(date)) <= 3_600 }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}
