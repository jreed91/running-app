import Foundation
import SwiftData

// MARK: - HeatAdvisoryService

/// Looks one day ahead, reads the forecast where the runner actually runs, and decides
/// whether tomorrow's session needs to change.
///
/// The split of responsibilities here is deliberate and worth keeping:
///
/// - `HeatAdaptationPolicy` holds every judgement and every number, and is pure.
/// - `WeatherService` holds every WeatherKit call.
/// - This type holds only the *plumbing* between them — which session, whose location,
///   what to persist, when to notify — so the interesting half of the feature stays
///   testable without a device, an entitlement, or a network.
@Observable
@MainActor
final class HeatAdvisoryService {

    /// The advisory the dashboard should be showing, or `nil`.
    ///
    /// Observable rather than fetched by the view: the refresh that produces it runs from
    /// the scene root on every foreground, several levels above the card that draws it, so
    /// a view reading storage in `.task` would only ever see the advisory that existed when
    /// it appeared. `AppNavigation` and `ActiveRunPresentation` are owned here for the same
    /// reason.
    private(set) var advisory: HeatAdvisory?

    @ObservationIgnored private let weatherService: WeatherService
    @ObservationIgnored private let notificationService: NotificationService
    @ObservationIgnored private let defaults: UserDefaults

    init(
        weatherService: WeatherService,
        notificationService: NotificationService,
        defaults: UserDefaults = .standard
    ) {
        self.weatherService = weatherService
        self.notificationService = notificationService
        self.defaults = defaults
    }

    /// Re-reads the published advisory from storage into `advisory`.
    ///
    /// Called at launch so an advisory written last night is on the dashboard before the
    /// forecast refresh has had a chance to run — and re-called by `refresh` so both paths
    /// agree on what "currently worth showing" means. Cheap: reads storage, never the
    /// network.
    @discardableResult
    func loadStoredAdvisory(now: Date = Date(), calendar: Calendar = .current) -> HeatAdvisory? {
        let stored = HeatAdvisoryStore.current(now: now, calendar: calendar, in: defaults)
        advisory = stored.flatMap { HeatAdvisoryStore.isAnswered($0, in: defaults) ? nil : $0 }
        return advisory
    }

    /// Records the runner's answer, so neither the card nor a notification asks again at
    /// this severity.
    func markAnswered(_ answered: HeatAdvisory) {
        HeatAdvisoryStore.markAnswered(answered, in: defaults)
        if advisory?.workoutID == answered.workoutID { advisory = nil }
    }

    // MARK: - Refresh

    /// Re-reads the forecast for tomorrow's session and republishes the advisory.
    ///
    /// Safe to call often: it returns early without touching WeatherKit when there is no
    /// eligible session, when the stored advisory is still fresh, or when the feature is
    /// off. Returns the live advisory when there is one, so a caller that wants to react
    /// immediately can, and `nil` otherwise.
    @discardableResult
    func refresh(
        plan: TrainingPlan?,
        recentRuns: [RunWorkout],
        isEnabled: Bool,
        unit: UnitPreference,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> HeatAdvisory? {
        guard isEnabled else {
            await clear()
            return nil
        }

        guard let session = Self.sessionNeedingAdvisory(in: plan, now: now, calendar: calendar) else {
            await retireAdvisoryUnlessItIsForToday(now: now, calendar: calendar)
            return loadStoredAdvisory(now: now, calendar: calendar)
        }

        // A fresh advisory for the same session is not worth a second WeatherKit call —
        // this runs on every foreground.
        if let stored = HeatAdvisoryStore.current(now: now, calendar: calendar, in: defaults),
           stored.workoutID == session.id {
            return loadStoredAdvisory(now: now, calendar: calendar)
        }

        guard let coordinate = Self.usualRunLocation(from: recentRuns) else {
            AppLogger.log(
                "No recorded run location yet — skipping heat advisory",
                label: "HeatAdvisory",
                level: .debug
            )
            return nil
        }

        let hour = Self.typicalRunHour(from: recentRuns, calendar: calendar)
        let forecast = await weatherService.hourlyForecast(
            at: coordinate,
            on: session.scheduledDate,
            calendar: calendar
        )
        guard !forecast.isEmpty else { return nil }

        guard let fresh = Self.advisory(
            for: session,
            forecast: forecast,
            plannedHour: hour,
            now: now,
            calendar: calendar
        ) else {
            // Tomorrow turned out fine. Retire anything left over from a worse forecast
            // rather than leaving the card up against weather that has since improved.
            await retireAdvisoryUnlessItIsForToday(now: now, calendar: calendar)
            return loadStoredAdvisory(now: now, calendar: calendar)
        }

        HeatAdvisoryStore.save(fresh, in: defaults)
        loadStoredAdvisory(now: now, calendar: calendar)

        guard !HeatAdvisoryStore.isAnswered(fresh, in: defaults) else { return nil }

        await notificationService.scheduleHeatAdvisory(fresh, unit: unit, now: now, calendar: calendar)
        AppLogger.log(
            "Heat advisory for \(fresh.workoutType.displayName) on "
                + "\(fresh.scheduledDate.formatted(.dateTime.month().day())): "
                + "\(fresh.tier.localizedName)",
            label: "HeatAdvisory",
            level: .info
        )
        return advisory
    }

    /// Drops the advisory and its pending notification. Used when the feature is switched
    /// off, when the plan no longer has a session to warn about, and by "Reset All Data".
    func clear(includingDismissals: Bool = false) async {
        if includingDismissals {
            HeatAdvisoryStore.clearAll(in: defaults)
        } else {
            HeatAdvisoryStore.clearCurrent(in: defaults)
        }
        advisory = nil
        await notificationService.cancelHeatAdvisories()
    }

    /// Takes down a published advisory that no longer has a session behind it — **unless
    /// that session is today's.**
    ///
    /// The distinction matters because "tomorrow" moves. An advisory published last night
    /// is about a run the runner has still not done at 07:00 this morning, and by then the
    /// notification's window has closed, so the dashboard card is the only surface left. A
    /// blanket clear on the first foreground of the session's own day would take it away
    /// exactly when it is finally being acted on.
    ///
    /// Anything older than that has already been dropped by `HeatAdvisoryStore.current`,
    /// so the only other case reaching here is an advisory for a session that stopped
    /// being eligible — completed, deleted, or moved indoors — which does go.
    private func retireAdvisoryUnlessItIsForToday(now: Date, calendar: Calendar) async {
        guard let stored = HeatAdvisoryStore.current(now: now, calendar: calendar, in: defaults) else {
            await notificationService.cancelHeatAdvisories()
            return
        }
        guard !calendar.isDate(stored.scheduledDate, inSameDayAs: now) else { return }
        await clear()
    }

    // MARK: - Pure decisions
    //
    // Static and injectable so the whole of the interesting behaviour is reachable from
    // `HeatAdvisoryServiceTests` without WeatherKit or a container.

    /// The session an advisory should be built for: **tomorrow's**, and only tomorrow's.
    ///
    /// The day before is the point at which the runner can still act — move the session to
    /// dawn, plan a treadmill, decide to swap it with Thursday's easy day — and it is late
    /// enough that the forecast is worth trusting. A warning three days out is a guess the
    /// runner cannot use; one on the morning itself is an excuse, not a plan.
    static func sessionNeedingAdvisory(
        in plan: TrainingPlan?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduledWorkout? {
        guard let plan, plan.isActive, !plan.isPregnancyPlan else { return nil }

        let tomorrow = calendar.startOfDay(for: now).addingTimeInterval(86_400)

        return (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter { calendar.isDate($0.scheduledDate, inSameDayAs: tomorrow) }
            .filter { HeatAdaptationPolicy.isAdvisable($0, now: now) }
            .sorted { $0.scheduledDate < $1.scheduledDate }
            .first
    }

    /// Builds the advisory for a session against a day's forecast, or `nil` when the
    /// conditions do not warrant one.
    ///
    /// Pure: every input is passed, nothing is read from storage, and the tier decision
    /// belongs entirely to `HeatAdaptationPolicy`.
    static func advisory(
        for workout: ScheduledWorkout,
        forecast: [ForecastHour],
        plannedHour: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HeatAdvisory? {
        guard let planned = closestHour(to: plannedHour, in: forecast, calendar: calendar) else {
            return nil
        }

        let tier = HeatAdaptationPolicy.tier(for: planned.conditions)
        guard HeatAdaptationPolicy.shouldPrompt(tier: tier, workoutType: workout.workoutType) else {
            return nil
        }

        return HeatAdvisory(
            workoutID: workout.id,
            workoutType: workout.workoutType,
            scheduledDate: workout.scheduledDate,
            plannedStart: planned.date,
            conditions: planned.conditions,
            tier: tier,
            cooler: coolerOption(than: planned, in: forecast, calendar: calendar),
            generatedAt: now
        )
    }

    /// The coolest hour inside the allowed window that is worth moving to, or `nil`.
    ///
    /// "Coolest" is by apparent temperature, but the *decision* is
    /// `HeatAdaptationPolicy.isWorthMoving(from:to:)` — a whole tier better and something
    /// the runner can feel. Both tests live in the policy so the threshold is documented
    /// alongside its source rather than buried in a sort.
    static func coolerOption(
        than planned: ForecastHour,
        in forecast: [ForecastHour],
        calendar: Calendar = .current
    ) -> HeatAdvisory.CoolerOption? {
        let candidate = forecast
            .filter { HeatAdaptationPolicy.coolerHourWindow.contains(calendar.component(.hour, from: $0.date)) }
            .min { $0.conditions.feelsLikeCelsius < $1.conditions.feelsLikeCelsius }

        guard
            let candidate,
            candidate.date != planned.date,
            HeatAdaptationPolicy.isWorthMoving(from: planned.conditions, to: candidate.conditions)
        else { return nil }

        return HeatAdvisory.CoolerOption(
            start: candidate.date,
            conditions: candidate.conditions,
            tier: HeatAdaptationPolicy.tier(for: candidate.conditions)
        )
    }

    /// The forecast reading nearest the hour the runner usually sets off.
    static func closestHour(
        to hour: Int,
        in forecast: [ForecastHour],
        calendar: Calendar = .current
    ) -> ForecastHour? {
        forecast.min {
            abs(calendar.component(.hour, from: $0.date) - hour)
                < abs(calendar.component(.hour, from: $1.date) - hour)
        }
    }

    /// The hour of day this runner tends to start at, from their recorded history.
    ///
    /// The **median** rather than the mean: one 22:00 run after a late flight should not
    /// drag a 07:00 runner's forecast into the evening, and a mean is exactly what would.
    /// Walks are excluded like every other training read (`runsOnly`) — the walk to the
    /// shops is not evidence about when this person runs.
    ///
    /// Falls back to 07:00 for a runner with no history yet, which is when the largest
    /// share of recreational running happens and, more to the point, is early enough that
    /// a forecast built on it errs toward under-stating the heat rather than over-stating
    /// it. An advisory that fires when it needn't is the failure mode that gets the
    /// feature switched off.
    static func typicalRunHour(
        from runs: [RunWorkout],
        calendar: Calendar = .current,
        lookback: Int = 20
    ) -> Int {
        let hours = runs.runsOnly
            .sorted { $0.date > $1.date }
            .prefix(lookback)
            .map { calendar.component(.hour, from: $0.date) }
            .sorted()

        guard !hours.isEmpty else { return defaultRunHour }
        return hours[hours.count / 2]
    }

    static let defaultRunHour = 7

    /// Where to ask about the weather: the start of the runner's most recent recorded run.
    ///
    /// No new permission and no location prompt — this is a coordinate the app already has
    /// — and it answers the question that actually matters, which is not "where is the
    /// phone this evening" but "where will this person be running tomorrow". A runner who
    /// is away from home has been running there too, so the answer follows them.
    static func usualRunLocation(from runs: [RunWorkout]) -> Coordinate? {
        for run in runs.runsOnly.sorted(by: { $0.date > $1.date }) {
            // Decoding the whole route to take its first point is wasteful, so it is done
            // once per run and stopped at the first that has one — a treadmill run or a
            // recorded-by-hand entry carries no coordinates at all.
            if let start = run.routeCoordinates.first { return start }
        }
        return nil
    }
}
