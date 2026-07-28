import Foundation

// MARK: - SmartCoachCard

/// One piece of coaching on the dashboard: what to eat before the next session, or what
/// to change about how the last few went.
struct SmartCoachCard: Identifiable, Equatable, Sendable {

    /// What the card is about. Doubles as the card's identity — at most one card of each
    /// kind is ever produced, so this is stable across rebuilds and SwiftUI can diff the
    /// list without the cards animating past each other on every render.
    enum Kind: String, Sendable, CaseIterable {
        /// Race day is inside the week: how to eat through the taper.
        case raceWeek
        /// A run finished within the recovery window.
        case refuel
        /// The next session is long enough to need fuelling *during* it.
        case longRunFuel
        /// The next session is hard enough to need fuelling *before* it.
        case sessionFuel
        /// Recent conditions were hot or humid enough to change the plan.
        case heat
        /// The last run's second half was materially slower than its first.
        case fade
        /// Easy runs and hard runs are being run at nearly the same pace.
        case polarization
        /// Cadence is sitting low across recent runs.
        case cadence
        /// Seven-day volume jumped well past the usual guideline.
        case load
        /// Nothing has been logged for long enough to need a way back in.
        case comeback
        /// Nothing else fired — a plain preparation note for the next session.
        case prep
    }

    /// Which half of the coaching a card belongs to. Rendered as the card's overline so a
    /// fuelling tip and a form tip are distinguishable at a glance.
    enum Category: String, Sendable {
        case nutrition
        case training
    }

    enum Tone: String, Sendable {
        case positive
        case neutral
        case caution
    }

    let kind: Kind
    let title: String
    let message: String
    let tone: Tone

    var id: String { kind.rawValue }

    var category: Category {
        switch kind {
        case .raceWeek, .refuel, .longRunFuel, .sessionFuel, .heat:
            return .nutrition
        case .fade, .polarization, .cadence, .load, .comeback, .prep:
            return .training
        }
    }
}

// MARK: - SmartCoachCards

/// Builds the dashboard's coaching cards from the plan and the runner's recent runs.
///
/// Deterministic and offline by design. Every rule below is a threshold over data the app
/// already holds — the next scheduled session, the last few runs, the weather stamped on
/// them, their splits and cadence — so the cards are there on the first render, on a
/// plane, and on a device whose on-device model is unavailable. That also makes every
/// rule testable, which is the part that matters: this is advice about training and
/// eating, and advice a test cannot pin is advice nobody can check.
///
/// Pure and stateless like ``WidgetSnapshotBuilder`` and ``StreakGoalService``, with an
/// injectable `now` and `calendar` throughout.
enum SmartCoachCards {

    /// How many cards the dashboard shows. Three is what fits above the free-run button
    /// without turning the screen into a reading list; the rest of the advice keeps until
    /// the situation that produced it is the most pressing one.
    static let defaultLimit = 3

    // MARK: Thresholds
    //
    // Named rather than inlined because they are the whole of each rule's judgement, and
    // because a threshold with a name is one a test can quote.

    /// A race inside this many days puts the runner in race week.
    static let raceWeekWindowDays = 7
    /// How long after a run the "refuel now" card stays up.
    static let refuelWindowSeconds: TimeInterval = 2 * 3_600
    /// Distance below which an easy run is not worth a refuelling prompt on its own.
    static let refuelMinimumDistanceMeters = 8_000.0
    /// Distance at which a long run needs carbohydrate taken during it.
    static let inRunFuelDistanceMeters = 16_000.0
    /// Duration at which the same becomes true regardless of distance.
    static let inRunFuelDurationSeconds: TimeInterval = 90 * 60
    /// Apparent temperature at which heat starts costing pace.
    static let heatFeelsLikeCelsius = 22.0
    /// Relative humidity that does the same on its own.
    static let heatHumidityPercent = 70.0
    /// How far back a weather reading still describes the conditions to expect.
    static let heatLookbackDays = 10
    /// Second-half slowdown, as a percentage, that counts as fading.
    static let fadePercent = 5.0
    /// Splits needed before a first-half/second-half comparison means anything.
    static let fadeMinimumSplits = 4
    /// How far back the easy-versus-hard comparison looks.
    static let polarizationLookbackDays = 28
    /// How much slower easy runs should be than quality runs, as a percentage.
    static let polarizationSeparationPercent = 8.0
    /// Cadence below which a turnover nudge is worth suggesting.
    static let cadenceFloorStepsPerMinute = 165.0
    /// How far back cadence is averaged, and how many readings are needed.
    static let cadenceLookbackDays = 21
    static let cadenceMinimumRuns = 3
    /// Seven-day volume increase, as a percentage, that counts as a jump.
    static let loadRampPercent = 20.0
    /// Volume the previous week has to reach before a ramp is meaningful rather than
    /// arithmetic on a near-zero base.
    static let loadMinimumPriorMeters = 10_000.0
    /// Days without a run that make coming back the most useful thing to say.
    static let comebackDays = 6

    // MARK: - Entry point

    /// The cards to show, most pressing first, at most one per kind.
    ///
    /// - Parameters:
    ///   - nextSession: the plan's next uncompleted session, counting from today. Nil when
    ///     there is no plan or nothing left in it.
    ///   - recentRuns: recent runs in any order; sorted newest-first internally so the
    ///     caller's query ordering cannot change the advice.
    ///   - profile: the runner's profile, for the race date.
    static func cards(
        nextSession: ScheduledWorkout?,
        recentRuns: [RunWorkout],
        profile: UserProfile?,
        unit: UnitPreference,
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = defaultLimit
    ) -> [SmartCoachCard] {
        guard limit > 0 else { return [] }
        let runs = recentRuns.sorted { $0.date > $1.date }

        // Ordered by how much the runner can still act on it: race week and the recovery
        // window close, the next session is hours or days away, and the trend cards keep.
        let ordered: [SmartCoachCard?] = [
            raceWeekCard(profile: profile, now: now, calendar: calendar),
            refuelCard(runs: runs, unit: unit, now: now),
            nextSessionFuelCard(nextSession: nextSession, unit: unit, now: now, calendar: calendar),
            heatCard(runs: runs, nextSession: nextSession, unit: unit, now: now),
            comebackCard(runs: runs, now: now, calendar: calendar),
            loadCard(runs: runs, unit: unit, now: now),
            fadeCard(runs: runs, unit: unit, now: now),
            polarizationCard(runs: runs, unit: unit, now: now),
            cadenceCard(runs: runs, now: now),
        ]

        let cards = ordered.compactMap { $0 }
        if cards.isEmpty {
            return prepCard(nextSession: nextSession, now: now, calendar: calendar).map { [$0] } ?? []
        }
        return Array(cards.prefix(limit))
    }

    // MARK: - Race week

    private static func raceWeekCard(
        profile: UserProfile?,
        now: Date,
        calendar: Calendar
    ) -> SmartCoachCard? {
        guard let profile, profile.goalRace.isGoalRace, let raceDate = profile.raceDate else { return nil }
        guard let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: raceDate)
        ).day, (0...raceWeekWindowDays).contains(days) else { return nil }

        let title: String
        let message: String
        switch days {
        case 0:
            title = String(localized: "Race day", comment: "Coach card title")
            message = String(
                localized: """
                Eat something carb-led two to three hours before the start, then sip rather \
                than gulp up to about twenty minutes out. Nothing you haven't already \
                practised on a long run — race morning is the worst possible time to meet a \
                new gel.
                """,
                comment: "Coach card body for race day"
            )
        case 1:
            title = String(localized: "Race is tomorrow", comment: "Coach card title")
            message = String(
                localized: """
                Top up carbohydrate across today rather than in one large dinner, keep the \
                fibre light, and drink to thirst through the afternoon. A short shakeout \
                run does more for tomorrow than another hour on the sofa.
                """,
                comment: "Coach card body for the day before a race"
            )
        default:
            title = String(localized: "Race week — \(days) days out", comment: "Coach card title")
            message = String(
                localized: """
                Volume drops through the taper but fuelling shouldn't. Hold your usual \
                carbohydrate intake so you reach the start line topped up, and lay out your \
                kit and gels now so race morning has no decisions left in it.
                """,
                comment: "Coach card body for race week"
            )
        }
        return SmartCoachCard(kind: .raceWeek, title: title, message: message, tone: .positive)
    }

    // MARK: - Refuel after a run

    /// The window straight after a hard or long run, while it is still actionable.
    ///
    /// Uses the run's *finish* — start plus duration — rather than its start date, so a
    /// two-hour long run does not fall out of a two-hour window before the runner has had
    /// a chance to get home.
    private static func refuelCard(
        runs: [RunWorkout],
        unit: UnitPreference,
        now: Date
    ) -> SmartCoachCard? {
        guard let run = runs.first else { return nil }
        let elapsed = now.timeIntervalSince(run.date.addingTimeInterval(run.durationSeconds))
        guard elapsed >= 0, elapsed <= refuelWindowSeconds else { return nil }

        let wasDemanding = run.distanceMeters >= refuelMinimumDistanceMeters
            || run.workoutType.isQualitySession
            || run.workoutType == .longRun
        guard wasDemanding else { return nil }

        let minutes = max(1, Int((elapsed / 60).rounded()))
        return SmartCoachCard(
            kind: .refuel,
            title: String(localized: "Refuel while the window's open", comment: "Coach card title"),
            message: String(
                localized: """
                You finished \(run.distanceMeters.distanceString(unit: unit)) about \
                \(minutes) minutes ago. Thirty to sixty grams of carbohydrate with around \
                twenty grams of protein in the next hour is when glycogen goes back \
                fastest, and it takes the edge off tomorrow.
                """,
                comment: "Coach card body shown shortly after a demanding run"
            ),
            tone: .positive
        )
    }

    // MARK: - Fuelling the next session

    private static func nextSessionFuelCard(
        nextSession: ScheduledWorkout?,
        unit: UnitPreference,
        now: Date,
        calendar: Calendar
    ) -> SmartCoachCard? {
        guard let workout = nextSession, workout.workoutType.isRunType else { return nil }

        let day = NextUpBriefing.dayPhrase(for: workout.scheduledDate, now: now, calendar: calendar)
        let type = workout.workoutType.localizedName
        let distance = workout.targetDistanceMeters ?? 0
        let duration = NextUpBriefing.estimatedDurationSeconds(for: workout) ?? 0
        let needsFuelDuring = distance >= inRunFuelDistanceMeters || duration >= inRunFuelDurationSeconds

        if needsFuelDuring {
            let lead = distance > 0
                ? String(
                    localized: "\(day)'s \(type) is \(distance.distanceString(unit: unit)).",
                    comment: "Coach card opening naming a long session and its distance"
                )
                : String(
                    localized: "\(day)'s \(type) goes past ninety minutes.",
                    comment: "Coach card opening naming a long session with no set distance"
                )
            return SmartCoachCard(
                kind: .longRunFuel,
                title: String(localized: "Practise your fuelling", comment: "Coach card title"),
                message: String(
                    localized: """
                    \(lead) Start it topped up, then take thirty to sixty grams of \
                    carbohydrate an hour from about forty-five minutes in, and carry 400–500 ml \
                    of fluid. The long run is where race-day fuelling gets rehearsed, not \
                    where you find out it disagrees with you.
                    """,
                    comment: "Coach card body for a session long enough to need fuel during it"
                ),
                tone: .neutral
            )
        }

        guard workout.workoutType.isQualitySession else { return nil }
        return SmartCoachCard(
            kind: .sessionFuel,
            title: String(localized: "Eat before the hard one", comment: "Coach card title"),
            message: String(
                localized: """
                \(day)'s \(type) runs on carbohydrate. A carb-led meal two to three hours \
                out, or a banana and a coffee forty-five minutes before, is the difference \
                between hitting the last rep and hanging on through it.
                """,
                comment: "Coach card body for a quality session"
            ),
            tone: .neutral
        )
    }

    // MARK: - Heat and hydration

    /// The app has no forecast — weather is stamped on runs *after* the fact — so the most
    /// recent reading stands in for the conditions to expect, and the copy says so rather
    /// than pretending to know what the next session will be like.
    private static func heatCard(
        runs: [RunWorkout],
        nextSession: ScheduledWorkout?,
        unit: UnitPreference,
        now: Date
    ) -> SmartCoachCard? {
        guard let next = nextSession, next.workoutType.isRunType, next.workoutLocation == .outdoor else {
            return nil
        }
        let cutoff = now.addingTimeInterval(-Double(heatLookbackDays) * 86_400)
        guard let weather = runs.first(where: { $0.date >= cutoff && $0.weather != nil })?.weather else {
            return nil
        }
        guard weather.feelsLikeCelsius >= heatFeelsLikeCelsius
                || weather.humidityPercent >= heatHumidityPercent else { return nil }

        let humidity = Int(weather.humidityPercent.rounded())
        return SmartCoachCard(
            kind: .heat,
            title: String(localized: "Drink ahead of the heat", comment: "Coach card title"),
            message: String(
                localized: """
                Your last run out there felt like \(weather.feelsLikeString(unit: unit)) at \
                \(humidity)% humidity. Take 400–500 ml in the two hours before you go, add \
                electrolytes if you'll be out over an hour, and let the pace sit 10–20 \
                seconds per \(unitWord(unit)) slower for the same effort.
                """,
                comment: "Coach card body for hot or humid conditions"
            ),
            tone: .caution
        )
    }

    // MARK: - Coming back

    private static func comebackCard(
        runs: [RunWorkout],
        now: Date,
        calendar: Calendar
    ) -> SmartCoachCard? {
        guard let last = runs.first else { return nil }
        guard let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: last.date),
            to: calendar.startOfDay(for: now)
        ).day, days >= comebackDays else { return nil }

        return SmartCoachCard(
            kind: .comeback,
            title: String(localized: "Ease back in", comment: "Coach card title"),
            message: String(
                localized: """
                It's been \(days) days since your last run. Come back with twenty to thirty \
                minutes easy rather than picking the plan up mid-week — one gentle run makes \
                the next one far more likely than one heroic session does.
                """,
                comment: "Coach card body after a gap in training"
            ),
            tone: .caution
        )
    }

    // MARK: - Weekly load

    /// A rolling seven-day window against the seven before it, rather than this calendar
    /// week against last: a Tuesday comparison of a part-week to a whole one always reads
    /// as a collapse in volume, which is the opposite of the warning this card exists for.
    private static func loadCard(
        runs: [RunWorkout],
        unit: UnitPreference,
        now: Date
    ) -> SmartCoachCard? {
        let week: TimeInterval = 7 * 86_400
        let recentStart = now.addingTimeInterval(-week)
        let priorStart = now.addingTimeInterval(-2 * week)

        let recent = runs
            .filter { $0.date > recentStart && $0.date <= now }
            .reduce(0.0) { $0 + $1.distanceMeters }
        let prior = runs
            .filter { $0.date > priorStart && $0.date <= recentStart }
            .reduce(0.0) { $0 + $1.distanceMeters }

        guard prior >= loadMinimumPriorMeters else { return nil }
        let change = (recent - prior) / prior * 100
        guard change >= loadRampPercent else { return nil }

        return SmartCoachCard(
            kind: .load,
            title: String(localized: "Big week — hold it there", comment: "Coach card title"),
            message: String(
                localized: """
                You've covered \(recent.distanceString(unit: unit)) in the last seven days, \
                \(Int(change.rounded()))% up on the seven before. Jumps much past 10% are \
                where niggles start — sit at this volume for a week before adding more, and \
                keep the easy days genuinely easy.
                """,
                comment: "Coach card body for a sharp increase in weekly volume"
            ),
            tone: .caution
        )
    }

    // MARK: - Fading

    private static func fadeCard(
        runs: [RunWorkout],
        unit: UnitPreference,
        now: Date
    ) -> SmartCoachCard? {
        guard let run = runs.first(where: { now.timeIntervalSince($0.date) <= 7 * 86_400 }) else {
            return nil
        }
        let splits = run.splits
            .filter { $0.paceSecondsPerKm > 0 }
            .sorted { $0.kilometer < $1.kilometer }
        guard splits.count >= fadeMinimumSplits else { return nil }

        // An odd split count drops its middle rather than counting it on both sides.
        let half = splits.count / 2
        let opening = average(splits.prefix(half).map(\.paceSecondsPerKm))
        let closing = average(splits.suffix(half).map(\.paceSecondsPerKm))
        guard opening > 0 else { return nil }

        let drift = (closing - opening) / opening * 100
        guard drift >= fadePercent else { return nil }

        return SmartCoachCard(
            kind: .fade,
            title: String(localized: "Start the next one slower", comment: "Coach card title"),
            message: String(
                localized: """
                You gave back \(Int(drift.rounded()))% over the back half of your last run — \
                \(opening.paceString(unit: unit)) early against \(closing.paceString(unit: unit)) \
                late. Open 10–15 seconds per \(unitWord(unit)) slower than feels right; the \
                back half usually hands it all back and then some.
                """,
                comment: "Coach card body for a run whose second half was slower"
            ),
            tone: .caution
        )
    }

    // MARK: - Easy days versus hard days

    private static func polarizationCard(
        runs: [RunWorkout],
        unit: UnitPreference,
        now: Date
    ) -> SmartCoachCard? {
        let cutoff = now.addingTimeInterval(-Double(polarizationLookbackDays) * 86_400)
        let window = runs.filter { $0.date >= cutoff && $0.averagePaceSecondsPerKm > 0 }

        let easy = window.filter { $0.workoutType == .easy }.map(\.averagePaceSecondsPerKm)
        let quality = window.filter { $0.workoutType.isQualitySession }.map(\.averagePaceSecondsPerKm)
        guard easy.count >= 2, !quality.isEmpty else { return nil }

        let easyPace = average(easy)
        let qualityPace = average(quality)
        guard qualityPace > 0 else { return nil }

        // Pace is seconds per unit distance, so slower is a *larger* number.
        let separation = (easyPace - qualityPace) / qualityPace * 100
        guard separation < polarizationSeparationPercent else { return nil }

        let comparison = separation <= 0
            ? String(
                localized: "as quick as your hard ones (\(qualityPace.paceString(unit: unit)))",
                comment: "Coach card clause when easy runs are no slower than quality runs"
            )
            : String(
                localized: """
                only \(Int(separation.rounded()))% slower than your hard ones \
                (\(qualityPace.paceString(unit: unit)))
                """,
                comment: "Coach card clause comparing easy-run pace to quality-run pace"
            )

        return SmartCoachCard(
            kind: .polarization,
            title: String(localized: "Let the easy days be easy", comment: "Coach card title"),
            message: String(
                localized: """
                Your easy runs are averaging \(easyPace.paceString(unit: unit)) — \(comparison). \
                Easy days that creep quick leave less for the sessions that actually build \
                speed. Try holding them 30–45 seconds per \(unitWord(unit)) further back.
                """,
                comment: "Coach card body when easy and hard runs are run at similar paces"
            ),
            tone: .neutral
        )
    }

    // MARK: - Cadence

    private static func cadenceCard(runs: [RunWorkout], now: Date) -> SmartCoachCard? {
        let cutoff = now.addingTimeInterval(-Double(cadenceLookbackDays) * 86_400)
        // A run recorded without a pedometer reading stores `nil` rather than zero, so it
        // drops out here instead of dragging the mean down toward the floor.
        let readings = runs
            .filter { $0.date >= cutoff }
            .compactMap { $0.averageCadenceStepsPerMinute }
            .filter { $0 > 0 }
        guard readings.count >= cadenceMinimumRuns else { return nil }

        let mean = average(readings)
        guard mean < cadenceFloorStepsPerMinute else { return nil }

        return SmartCoachCard(
            kind: .cadence,
            title: String(localized: "Nudge your turnover up", comment: "Coach card title"),
            message: String(
                localized: """
                Your last \(readings.count) runs averaged \(Int(mean.rounded())) steps a \
                minute. Lifting that about 5% — roughly \(Int((mean * 1.05).rounded())) — \
                shortens the stride and puts each foot down under you rather than out in \
                front of you. Try it on the easy days first.
                """,
                comment: "Coach card body for low running cadence"
            ),
            tone: .neutral
        )
    }

    // MARK: - Fallback

    /// What to say when nothing else fired, so the section is a steady part of the screen
    /// rather than one that blinks in and out as thresholds are crossed.
    private static func prepCard(
        nextSession: ScheduledWorkout?,
        now: Date,
        calendar: Calendar
    ) -> SmartCoachCard? {
        guard let workout = nextSession, workout.workoutType.isRunType else { return nil }
        let day = NextUpBriefing.dayPhrase(for: workout.scheduledDate, now: now, calendar: calendar)
        let type = workout.workoutType.localizedName

        return SmartCoachCard(
            kind: .prep,
            title: String(localized: "Set yourself up for it", comment: "Coach card title"),
            message: String(
                localized: """
                \(day)'s \(type) is on the plan and nothing in your recent runs needs \
                fixing. Lay the kit out the night before, drink a glass of water when you \
                wake, and eat something small and carb-led if you're heading out more than \
                an hour after breakfast.
                """,
                comment: "Coach card body shown when no other rule applies"
            ),
            tone: .positive
        )
    }

    // MARK: - Helpers

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// The distance unit as it is spoken in a sentence — "per km", "per mile" — rather
    /// than as the abbreviation a metric cell uses.
    private static func unitWord(_ unit: UnitPreference) -> String {
        switch unit {
        case .metric:   return String(localized: "km", comment: "Distance unit inside coach copy")
        case .imperial: return String(localized: "mile", comment: "Distance unit inside coach copy")
        }
    }
}
