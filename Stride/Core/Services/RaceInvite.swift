import Foundation

// MARK: - RaceInvite

/// A goal race as a link a runner can send a friend: "Train with a friend" in the race hub.
///
/// The link carries the race and nothing about the runner: its name, its day and its
/// distance. A friend who opens it gets a plan to the same day at their own paces, built
/// from their own answers, so nothing personal has to travel and no account or server is
/// involved. The race hub sends it; opening one is handled where `stride://` links are.
///
/// Two spellings of one link:
///
/// - ``webURL``, `https://runwithstride.app/race?…`, the one that is shared. A phone
///   with Stride opens it in the app (once the site serves the app-site association);
///   one without it gets a page with the race and the App Store button.
/// - ``appURL``, `stride://race?…`, the same query on the app's own scheme, for the web
///   page's "Open in Stride" button.
///
/// Pure and Foundation-only, so every rule here is assertable without a screen.
struct RaceInvite: Equatable, Sendable {

    /// The race's name as the runner gave it, tidied: one line, no control characters, at
    /// most ``maxNameLength`` characters.
    let name: String
    /// Never `.maintainFitness`: that is a plan with no race, and there is nothing to share.
    let raceType: RaceType
    /// Set only when `raceType == .custom`, in whole metres.
    let customDistanceMeters: Double?
    /// The race day as a Gregorian calendar day, not an instant. A race is on the 12th
    /// wherever the friend opens the link; an instant would move it a day for a friend a
    /// few time zones west.
    let day: Day

    struct Day: Equatable, Sendable {
        let year: Int
        let month: Int
        let day: Int
    }

    // MARK: Limits

    /// Longer names are cut here, so a link stays a sensible length in a message.
    static let maxNameLength = 80

    /// The custom distances a link may carry: the same span the plan setup offers, with
    /// room either side, so a hand-edited link cannot ask for a 0 m or a 1,000 km race.
    static let customDistanceRange: ClosedRange<Double> = 1_000...250_000

    /// Years a link may name. Anything outside is a typo or a hand-made link.
    static let yearRange: ClosedRange<Int> = 2000...2100

    // MARK: Wire format

    static let webScheme = "https"
    /// The bare domain, because `www.` answers with a redirect to it, and iOS neither opens
    /// the app for a link that redirects nor fetches the app-site association through one.
    /// The site's Worker (jacobreed.dev repo, `cloudflare/stride/`) serves both.
    static let webHost = "runwithstride.app"
    static let webHosts: Set<String> = [webHost, "www.runwithstride.app"]
    static let webPath = "/race"
    static let appHost = "race"

    private enum Key {
        static let name = "name"
        static let date = "date"
        static let distance = "distance"
    }

    /// The `distance` values for the named races. Short and readable, because the link is
    /// on show in the message it is sent in.
    private static let distanceSlugs: [RaceType: String] = [
        .fiveK: "5k",
        .tenK: "10k",
        .halfMarathon: "half",
        .marathon: "marathon",
    ]

    // MARK: Init

    /// An invite for a race, or nil when there is no race to share (`.maintainFitness`, a
    /// custom distance outside ``customDistanceRange``, a date outside ``yearRange``).
    ///
    /// - Parameters:
    ///   - raceDate: any instant on the race day, read in `calendar`'s time zone.
    ///   - calendar: the sharer's calendar; only its time zone is used, so a device set to
    ///     another calendar system still sends a Gregorian day.
    init?(
        name: String,
        raceType: RaceType,
        customDistanceMeters: Double? = nil,
        raceDate: Date,
        calendar: Calendar = .current
    ) {
        guard raceType.isGoalRace else { return nil }

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: raceDate)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }

        self.init(
            name: name,
            raceType: raceType,
            customDistanceMeters: customDistanceMeters,
            day: Day(year: year, month: month, day: dayOfMonth)
        )
    }

    /// The invite the race hub shares for `racePlan`.
    init?(racePlan: RaceDayPlan, calendar: Calendar = .current) {
        self.init(
            name: racePlan.raceName,
            raceType: racePlan.raceType,
            customDistanceMeters: racePlan.raceType.usesCustomDistance ? racePlan.distanceMeters : nil,
            raceDate: racePlan.raceDate,
            calendar: calendar
        )
    }

    private init?(name: String, raceType: RaceType, customDistanceMeters: Double?, day: Day) {
        guard raceType.isGoalRace else { return nil }
        guard Self.yearRange.contains(day.year), Self.isRealDay(day) else { return nil }

        if raceType.usesCustomDistance {
            guard let meters = customDistanceMeters, meters.isFinite else { return nil }
            let whole = meters.rounded()
            guard Self.customDistanceRange.contains(whole) else { return nil }
            self.customDistanceMeters = whole
        } else {
            self.customDistanceMeters = nil
        }

        let tidied = Self.tidiedName(name)
        self.name = tidied.isEmpty ? raceType.displayName : tidied
        self.raceType = raceType
        self.day = day
    }

    /// Reads an invite from either spelling of the link, or nil when `url` is not one or
    /// says something an invite cannot (no date, an unknown distance, a 31st of February).
    init?(url: URL) {
        guard Self.isInviteURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            // The first of a repeated key wins, the way a reader would take the link.
            if values[item.name] == nil, let value = item.value {
                values[item.name] = value
            }
        }

        guard let dateText = values[Key.date],
              let day = Self.parseDay(dateText),
              let distanceText = values[Key.distance],
              let (raceType, customMeters) = Self.parseDistance(distanceText)
        else { return nil }

        self.init(
            name: values[Key.name] ?? "",
            raceType: raceType,
            customDistanceMeters: customMeters,
            day: day
        )
    }

    // MARK: Reading

    /// The race distance in metres.
    var distanceMeters: Double {
        customDistanceMeters ?? raceType.distanceMeters
    }

    /// The start of the race day in `calendar`'s time zone: the date a plan is built to.
    func raceDate(calendar: Calendar = .current) -> Date? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }

    /// Whether the race day is before today in `calendar`: an invite opened after the race
    /// has nothing left to train for.
    func hasPassed(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let raceDate = raceDate(calendar: calendar) else { return true }
        return calendar.startOfDay(for: raceDate) < calendar.startOfDay(for: now)
    }

    /// The link that is shared: `https://runwithstride.app/race?…`.
    var webURL: URL {
        var components = URLComponents()
        components.scheme = Self.webScheme
        components.host = Self.webHost
        components.path = Self.webPath
        components.percentEncodedQuery = percentEncodedQuery
        // Built from fixed parts and percent-encoded values, so it always forms a URL.
        return components.url!
    }

    /// The same invite on the app's own scheme: `stride://race?…`.
    var appURL: URL {
        var components = URLComponents()
        components.scheme = RaceInviteLink.scheme
        components.host = Self.appHost
        components.percentEncodedQuery = percentEncodedQuery
        return components.url!
    }

    /// The query, with `+` encoded too: `URLComponents` leaves it bare, and a web page
    /// reading the link with `URLSearchParams` would take a bare `+` for a space.
    private var percentEncodedQuery: String? {
        var components = URLComponents()
        components.queryItems = queryItems
        return components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }

    private var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: Key.name, value: name),
            URLQueryItem(name: Key.date, value: Self.dayText(day)),
            URLQueryItem(name: Key.distance, value: distanceText),
        ]
    }

    private var distanceText: String {
        if let customDistanceMeters {
            return String(Int(customDistanceMeters))
        }
        return Self.distanceSlugs[raceType] ?? ""
    }

    // MARK: Parsing

    /// Whether `url` is an invite link at all, before its query is read. The app's
    /// `onOpenURL` asks this to tell an invite from a widget or Live Activity link.
    static func isInviteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == RaceInviteLink.scheme {
            return host == appHost
        }
        guard scheme == webScheme, webHosts.contains(host) else { return false }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.lowercased() == webPath
    }

    private static func parseDistance(_ text: String) -> (RaceType, Double?)? {
        let slug = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let match = distanceSlugs.first(where: { $0.value == slug }) {
            return (match.key, nil)
        }
        // Whole metres only: digits, nothing else, so "5e3" or "-1" are refused.
        guard !slug.isEmpty, slug.count <= 7, slug.allSatisfy(\.isASCIIDigit),
              let meters = Double(slug)
        else { return nil }
        return (.custom, meters)
    }

    /// `YYYY-MM-DD`, digits only, the form ``dayText(_:)`` writes.
    private static func parseDay(_ text: String) -> Day? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return Day(year: year, month: month, day: day)
    }

    private static func dayText(_ day: Day) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    /// Whether `day` exists on the Gregorian calendar: 2027-02-30 does not.
    private static func isRealDay(_ day: Day) -> Bool {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        return DateComponents(year: day.year, month: day.month, day: day.day).isValidDate(in: gregorian)
    }

    /// One line of printable text, runs of whitespace closed up, cut to ``maxNameLength``.
    static func tidiedName(_ raw: String) -> String {
        // Scalar by scalar, so an emoji or an accent built from several scalars survives.
        // Only control characters and line breaks go: format characters such as the
        // zero-width joiner inside a family emoji are part of what the runner typed.
        var printable = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let category = scalar.properties.generalCategory
            let breaks = category == .control || category == .lineSeparator || category == .paragraphSeparator
            printable.append(breaks ? " " : scalar)
        }
        let words = String(printable).split(whereSeparator: \.isWhitespace)
        let joined = words.joined(separator: " ")
        guard joined.count > maxNameLength else { return joined }
        return String(joined.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Identifiable

extension RaceInvite: Identifiable {
    /// The link itself: two invites to the same race on the same day are the same invite.
    var id: String { webURL.absoluteString }
}

// MARK: - RaceInviteLink

/// The app's URL scheme as invites spell it. The same `stride` scheme the Live Activity
/// and widgets use, named here so this file stays free of ActivityKit's attributes file.
enum RaceInviteLink {
    static let scheme = "stride"
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
