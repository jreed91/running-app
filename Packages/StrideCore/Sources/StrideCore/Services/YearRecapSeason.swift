import Foundation

/// When the year-in-running recap is offered, and for which year.
///
/// The recap is always reachable from Achievements (so a runner, or App Review, can open it
/// any day). Home only nudges during the season people look back: December, and January
/// for anyone who didn't get to it before New Year. Through January the recap offered is
/// last year's, which by then is complete.
public enum YearRecapSeason {

    /// The year whose recap the app offers at `now`: last year's in January, this year's
    /// from February on.
    public static func recapYear(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let year = calendar.component(.year, from: now)
        return calendar.component(.month, from: now) == 1 ? year - 1 : year
    }

    /// Whether Home shows the recap card: 1 December to 31 January.
    public static func isHomeSeason(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let month = calendar.component(.month, from: now)
        return month == 12 || month == 1
    }

    /// The first and last instant of `year`, for counting its runs without loading them.
    public static func interval(of year: Int, calendar: Calendar = .current) -> DateInterval? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

    /// `AppStorage` key holding the recap year the runner closed the Home card for, so it
    /// stays closed for that year and comes back for the next.
    public static let homeDismissedYearKey = "yearRecap.homeDismissedYear"
}
