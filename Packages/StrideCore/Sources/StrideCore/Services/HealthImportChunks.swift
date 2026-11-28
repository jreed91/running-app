import Foundation

// MARK: - HealthImportChunks

/// Splits a long "Import from Apple Health" range into short stretches, newest first.
///
/// The import used to read the whole range in one go: every run's route, heart-rate
/// samples and distance series for up to five years, held in memory at once, inserted
/// at once and saved at once, then a WeatherKit request per run. Years of runs ran the
/// phone out of memory and the app was killed mid-import. A stretch at a time is read,
/// saved and let go before the next, so memory stays at one stretch's worth whatever the
/// range, and what was imported before a failure stays imported.
///
/// Newest first, so the runs a runner cares about most land first.
enum HealthImportChunks {
    /// A month of running is a few dozen workouts at most.
    static let defaultDays = 30

    /// Weather is fetched only for runs this recent. It feeds the coach's look at recent
    /// runs and the heat tips; a WeatherKit request for every run of the last five years
    /// was hundreds of requests for nothing anyone reads.
    static let weatherDays = 14

    /// `[start, end)` stretches of at most `days` days covering `start` to `end`, newest
    /// first. Empty when `start` is not before `end`.
    static func ranges(from start: Date, to end: Date, days: Int = defaultDays) -> [DateInterval] {
        guard start < end, days > 0 else { return [] }
        let length = Double(days) * 86_400
        var result: [DateInterval] = []
        var upper = end
        while upper > start {
            let lower = max(start, upper.addingTimeInterval(-length))
            result.append(DateInterval(start: lower, end: upper))
            upper = lower
        }
        return result
    }

    /// Whether a run on `date` gets weather attached when imported at `now`.
    static func wantsWeather(_ date: Date, now: Date) -> Bool {
        date >= now.addingTimeInterval(-Double(weatherDays) * 86_400)
    }
}
