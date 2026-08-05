import Foundation

// MARK: - HeatAdvisory

/// One session, one day's forecast, and what Stride thinks about the pair.
///
/// Codable and stored in `UserDefaults` rather than SwiftData, deliberately. An advisory
/// is derived data with a lifespan of about a day: it is rebuilt from the plan and the
/// forecast whenever the app runs, it is worthless the moment the session is behind the
/// runner, and it describes a *forecast* rather than anything that happened. Putting it in
/// the store would mean a new `@Model`, a CloudKit schema deployment, and rows syncing
/// between devices that will each re-derive it more accurately from their own location.
struct HeatAdvisory: Codable, Equatable, Identifiable, Sendable {

    /// The session this is about. Doubles as identity — there is at most one live advisory
    /// per session — so a rebuild replaces rather than accumulates.
    let workoutID: UUID
    let workoutType: WorkoutType
    /// The session's scheduled day, as the plan holds it.
    let scheduledDate: Date
    /// The instant the forecast was read for: the runner's usual hour on that day.
    let plannedStart: Date
    /// Conditions at `plannedStart`.
    let conditions: WorkoutWeather
    let tier: HeatStressTier
    /// A materially better hour on the same day, when one exists.
    let cooler: CoolerOption?
    /// When this was computed, so a stale forecast can be refreshed rather than trusted.
    let generatedAt: Date

    var id: UUID { workoutID }

    /// An hour the session could move to that would genuinely change what it costs.
    ///
    /// Only ever populated when `HeatAdaptationPolicy.isWorthMoving(from:to:)` agrees, so
    /// the presence of this value is itself the recommendation — the UI does not re-decide.
    struct CoolerOption: Codable, Equatable, Sendable {
        let start: Date
        let conditions: WorkoutWeather
        let tier: HeatStressTier
    }

    /// Whether this advisory has outlived its session or its forecast.
    ///
    /// Two ways to go off, and both matter. A forecast read three days ago is not the
    /// forecast any more, and an advisory for yesterday's run is advice about the past.
    func isStale(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if now >= calendar.startOfDay(for: scheduledDate).addingTimeInterval(86_400) { return true }
        return now.timeIntervalSince(generatedAt) > Self.forecastLifetime
    }

    /// How long a fetched forecast is trusted before it is refetched. Six hours: long
    /// enough that opening the app repeatedly costs no WeatherKit calls, short enough that
    /// the evening notification is scheduled off a forecast made the same afternoon.
    static let forecastLifetime: TimeInterval = 6 * 3600
}

// MARK: - HeatAdvisoryStore

/// Where the live advisory and the runner's answer to it are kept.
///
/// Split from the service so the persistence rules are testable against a
/// `UserDefaults(suiteName:)` double without standing up WeatherKit, a plan, or a
/// container.
enum HeatAdvisoryStore {

    private static let advisoryKey = "heatAdvisory.current"
    private static let dismissalKeyPrefix = "heatAdvisory.dismissed."

    // MARK: The advisory itself

    static func save(_ advisory: HeatAdvisory, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(advisory) else { return }
        defaults.set(data, forKey: advisoryKey)
    }

    /// The stored advisory, or `nil` when there is none, it no longer decodes, or it has
    /// gone stale. A stale advisory is cleared on read rather than returned: every caller
    /// would otherwise have to remember to check, and the one that forgets shows the
    /// runner yesterday's weather.
    static func current(
        now: Date = Date(),
        calendar: Calendar = .current,
        in defaults: UserDefaults = .standard
    ) -> HeatAdvisory? {
        guard
            let data = defaults.data(forKey: advisoryKey),
            let advisory = try? JSONDecoder().decode(HeatAdvisory.self, from: data)
        else { return nil }

        guard !advisory.isStale(now: now, calendar: calendar) else {
            clearCurrent(in: defaults)
            return nil
        }
        return advisory
    }

    static func clearCurrent(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: advisoryKey)
    }

    // MARK: Dismissals

    /// Records that the runner has answered this advisory — by applying it, or by saying
    /// they will run it as planned.
    ///
    /// Keyed by session **and tier**, which is the whole point: dismissing a `.moderate`
    /// advisory settles the moderate one, and the card and the notification stay quiet.
    /// If tomorrow's forecast then worsens to `.severe`, that is new information about a
    /// materially different day, and the runner gets asked again. A dismissal keyed by
    /// session alone would swallow it.
    static func markAnswered(_ advisory: HeatAdvisory, in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: dismissalKey(advisory))
    }

    static func isAnswered(_ advisory: HeatAdvisory, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: dismissalKey(advisory))
    }

    private static func dismissalKey(_ advisory: HeatAdvisory) -> String {
        "\(dismissalKeyPrefix)\(advisory.workoutID.uuidString).\(advisory.tier.rawValue)"
    }

    /// Drops every stored dismissal. Called from "Reset All Data" alongside the advisory
    /// itself — the dismissals name workouts that no longer exist, and they would
    /// otherwise silently suppress the first advisory of a freshly generated plan whose
    /// session happened to be restored under the same identifier.
    static func clearAll(in defaults: UserDefaults = .standard) {
        clearCurrent(in: defaults)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(dismissalKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
