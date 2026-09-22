import Foundation

// MARK: - SmartCoachCards

/// Chooses the coaching cards — for the dashboard, the widgets, and Siri alike.
///
/// The selection is the feature. It runs in three steps, and each one exists because the
/// previous design got something wrong:
///
/// 1. **Resolve the situation** (``CoachSituation``). Every state has exactly one card,
///    including the states where the plan has nothing to say — a rest day, a plan that
///    has not started, a plan that is over, no plan at all. Those four used to share a
///    single "nothing scheduled" fallback, which said the same thing about four
///    different problems.
/// 2. **Short-circuit the exclusive states.** On race morning, in race week, or after a
///    fortnight off, the situation's card takes the whole strip. A second card there is
///    not extra help, it is something to read past.
/// 3. **Otherwise, score everything and rank.** The situation's card competes with every
///    signal the runner's data supports, and the highest score leads. That is what makes
///    a 40% volume jump able to outrank a routine long-run fuelling note, while a 21%
///    one cannot.
///
/// Deterministic and offline by design. Every score is a threshold over data the app
/// already holds, so the cards are there on first render, on a plane, and on a device
/// whose on-device model is unavailable — and every rule is pinned on both sides of its
/// threshold in tests, which is the part that matters for advice about training and
/// eating.
///
/// ## Three surfaces, one selection
///
/// The dashboard runs this directly. **App Intents** run it directly too — they open the
/// same store through `IntentDataProvider`, so Siri answers from the same thresholds
/// rather than a second opinion. The **widget extension cannot**: it is a separate
/// process with no access to SwiftData, so the app runs the selection and publishes the
/// winning card into ``WidgetSnapshot`` as finished strings, exactly as it does for every
/// other widget field. That is what `SmartCoachCard.glance` and
/// `SmartCoachCard.expiresAt` are for — see their notes on why a widget-bound card must
/// not have a clock in its wording.
///
/// Pure and stateless, with an injectable `now` and `calendar` throughout.
enum SmartCoachCards {

    /// How many cards the strip shows: one primary and two supporting.
    static let defaultLimit = 3

    // MARK: - Input

    /// Everything the selection reads, gathered once.
    ///
    /// A struct rather than nine parameters threaded through every rule: the signal rules
    /// each need a different subset, and passing them individually meant each new signal
    /// changed the signature of everything it sat beside.
    struct Context {
        var nextSession: ScheduledWorkout?
        var recentRuns: [RunWorkout]
        var profile: UserProfile?
        var dayState: ScheduledDayResolver.DayState
        var unit: UnitPreference
        /// Last night's HRV, resting heart rate and sleep from Apple Health, when the
        /// caller has read them. Only the dashboard does: the widget and Siri build their
        /// context without a HealthKit read, so the readiness card is a dashboard card.
        var recoveryReadings: RecoveryReadings?
        var now: Date
        var calendar: Calendar

        init(
            nextSession: ScheduledWorkout?,
            recentRuns: [RunWorkout],
            profile: UserProfile?,
            dayState: ScheduledDayResolver.DayState,
            unit: UnitPreference,
            recoveryReadings: RecoveryReadings? = nil,
            now: Date = Date(),
            calendar: Calendar = .current
        ) {
            self.nextSession = nextSession
            // Sorted once, here, so no rule downstream can be affected by the order the
            // caller's query happened to return — and narrowed to runs for the same
            // reason: every rule reads this as running history, so "you haven't run in
            // twelve days" must not be answered by a walk (N38).
            self.recentRuns = recentRuns.runsOnly.sorted { $0.date > $1.date }
            self.profile = profile
            self.dayState = dayState
            self.unit = unit
            self.recoveryReadings = recoveryReadings
            self.now = now
            self.calendar = calendar
        }

        /// The runner's body mass, if it is plausible. Drives every computed amount in
        /// ``CoachNutrition``; `nil` means the fuelling cards quote guideline ranges.
        var bodyMassKilograms: Double? {
            CoachNutrition.validMass(profile?.bodyMassKilograms)
        }

        /// The readiness score from ``recoveryReadings`` and the runs above, or `nil`
        /// when Health had nothing to go on.
        var readiness: RecoveryReadiness? {
            guard let recoveryReadings, !recoveryReadings.isEmpty else { return nil }
            return RecoveryReadiness.evaluate(
                readings: recoveryReadings,
                runs: recentRuns,
                now: now,
                calendar: calendar
            )
        }

        /// Midnight at the end of race day, for the race cards' expiry.
        ///
        /// Derived from the race date rather than from `now` on purpose: an expiry
        /// computed as "two hours from this write" moves on every write, and a snapshot
        /// that differs on every write spends a WidgetKit reload on every foreground.
        var endOfRaceDay: Date? {
            guard let raceDate = profile?.raceDate else { return nil }
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: raceDate))
        }
    }

    // MARK: - Entry point

    /// The strip, primary first.
    static func cards(_ context: Context, limit: Int = defaultLimit) -> [SmartCoachCard] {
        guard limit > 0 else { return [] }

        let situation = CoachSituation.resolve(
            nextSession: context.nextSession,
            recentRuns: context.recentRuns,
            profile: context.profile,
            dayState: context.dayState,
            now: context.now,
            calendar: context.calendar
        )

        let situationCard = card(for: situation, context: context)

        // Race day, race week, and a long lay-off own the strip outright.
        if situation.isExclusive {
            return situationCard.map { [$0] } ?? []
        }

        let candidates = ([situationCard] + signals(context))
            .compactMap { $0 }
            .filter { $0.score > 0 }

        // Score descending, then by kind so two cards that tie cannot swap places between
        // renders — which would show up as the strip reshuffling itself while being read.
        let ranked = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return Array(ranked.prefix(limit))
    }

    // MARK: - Situation cards

    /// The one card the runner's current state always has to offer.
    static func card(for situation: CoachSituation, context: Context) -> SmartCoachCard? {
        switch situation {
        case .raceDay:
            return raceDayCard(context)
        case .raceWeek(let daysOut):
            return raceWeekCard(daysOut: daysOut, expiresAt: context.endOfRaceDay)
        case .returningFromLayoff(let days):
            return comebackCard(days: days)
        case .recovering(let minutes):
            return refuelCard(minutesSinceFinish: minutes, context: context)
        case .sessionAhead(let shape):
            return sessionCard(shape: shape, context: context)
        case .restDay:
            return restDayCard(context)
        case .beforePlanStart(let days):
            return planStartsSoonCard(daysUntilStart: days)
        case .planFinished:
            return planFinishedCard()
        case .noPlan:
            return noPlanCard()
        }
    }

    // MARK: Race

    private static func raceDayCard(_ context: Context) -> SmartCoachCard {
        let carbs = CoachNutrition.preSessionCarbohydrate(
            bodyMassKg: context.bodyMassKilograms,
            unit: context.unit
        )
        return SmartCoachCard(
            kind: .raceDay,
            title: String(localized: "Race day", comment: "Coach card title"),
            message: String(
                localized: """
                Take \(carbs.amount) two to three hours before the start, then sip rather \
                than gulp up to about twenty minutes out. Nothing you haven't already \
                practised on a long run — race morning is the worst possible time to meet \
                a new gel.
                """,
                comment: "Coach card body for race day"
            ),
            glance: String(
                localized: "\(carbs.amount) two to three hours before the start. Nothing new.",
                comment: "Short coach tip for race day"
            ),
            tone: .positive,
            score: 1,
            derivation: carbs.derivation,
            expiresAt: context.endOfRaceDay
        )
    }

    private static func raceWeekCard(daysOut: Int, expiresAt: Date?) -> SmartCoachCard {
        let title = daysOut == 1
            ? String(localized: "Race is tomorrow", comment: "Coach card title")
            : String(localized: "Race week — \(daysOut) days out", comment: "Coach card title")
        let message = daysOut == 1
            ? String(
                localized: """
                Top up carbohydrate across today rather than in one large dinner, keep the \
                fibre light, and drink to thirst through the afternoon. A short shakeout \
                run does more for tomorrow than another hour on the sofa.
                """,
                comment: "Coach card body for the day before a race"
            )
            : String(
                localized: """
                Volume drops through the taper but fuelling shouldn't. Hold your usual \
                carbohydrate intake so you reach the start line topped up, and lay out \
                your kit and gels now so race morning has no decisions left in it.
                """,
                comment: "Coach card body for race week"
            )

        return SmartCoachCard(
            kind: .raceWeek,
            title: title,
            message: message,
            glance: String(
                localized: "Hold your usual carbohydrate through the taper so you start topped up.",
                comment: "Short coach tip for race week"
            ),
            tone: .positive,
            score: 1,
            expiresAt: expiresAt
        )
    }

    // MARK: Lay-off

    private static func comebackCard(days: Int) -> SmartCoachCard {
        SmartCoachCard(
            kind: .comeback,
            title: String(localized: "Ease back in", comment: "Coach card title"),
            message: String(
                localized: """
                It's been \(days) days since your last run. Come back with twenty to thirty \
                minutes easy rather than picking the plan up mid-week — one gentle run \
                makes the next one far more likely than one heroic session does.
                """,
                comment: "Coach card body after a gap in training"
            ),
            // No day count: it grows while the snapshot sits on disk, and the advice is
            // the same whether it has been six days or sixteen.
            glance: String(
                localized: "Come back with twenty to thirty minutes easy, not where the plan left off.",
                comment: "Short coach tip after a gap in training"
            ),
            tone: .caution,
            score: 1,
            derivation: String(
                localized: "\(days) days since your last run",
                comment: "Derivation line for the comeback card"
            )
        )
    }

    // MARK: Recovery window

    /// Decays across the window: the advice is worth acting on immediately and barely
    /// worth reading two hours later, and the score should say so rather than holding the
    /// top slot for the whole time.
    private static func refuelCard(minutesSinceFinish: Int, context: Context) -> SmartCoachCard? {
        guard let run = context.recentRuns.first else { return nil }
        let intake = CoachNutrition.recovery(
            bodyMassKg: context.bodyMassKilograms,
            unit: context.unit
        )
        let windowMinutes = CoachSituation.recoveryWindowSeconds / 60
        let remaining = 1 - (Double(minutesSinceFinish) / windowMinutes).clamped(to: 0...1)

        return SmartCoachCard(
            kind: .refuel,
            title: String(localized: "Refuel while the window's open", comment: "Coach card title"),
            message: String(
                localized: """
                You finished \(run.distanceMeters.distanceString(unit: context.unit)) about \
                \(minutesSinceFinish) minutes ago. \(intake.amount) in the next hour is \
                when glycogen goes back fastest, and it takes the edge off tomorrow.
                """,
                comment: "Coach card body shown shortly after a demanding run"
            ),
            // The elapsed minutes are deliberately absent. This is the card that proves
            // why: written into the snapshot they would be wrong within the hour, and
            // they would make the snapshot differ on every single write.
            glance: String(
                localized: "\(intake.amount) within the hour.",
                comment: "Short coach tip shown shortly after a demanding run"
            ),
            tone: .positive,
            // Floors at 0.45 rather than zero: even late in the window this outranks a
            // routine preparation note, because it expires and that one does not.
            score: 0.45 + 0.55 * remaining,
            derivation: intake.derivation,
            // Anchored to the run's finish, so it is the same instant on every write.
            expiresAt: run.date
                .addingTimeInterval(run.durationSeconds)
                .addingTimeInterval(CoachSituation.recoveryWindowSeconds)
        )
    }

    // MARK: The next session

    private static func sessionCard(
        shape: CoachSituation.SessionShape,
        context: Context
    ) -> SmartCoachCard? {
        guard let workout = context.nextSession else { return nil }
        let day = NextUpBriefing.dayPhrase(
            for: workout.scheduledDate,
            now: context.now,
            calendar: context.calendar
        )
        let type = workout.workoutType.localizedName

        switch shape {
        case .enduring:
            let duration = NextUpBriefing.estimatedDurationSeconds(for: workout) ?? 0
            let carbs = CoachNutrition.inSessionCarbohydrate(
                bodyMassKg: context.bodyMassKilograms,
                durationSeconds: duration,
                unit: context.unit
            )
            let fluid = CoachNutrition.fluid(
                bodyMassKg: context.bodyMassKilograms,
                feelsLikeCelsius: recentFeelsLike(context),
                unit: context.unit
            )
            return SmartCoachCard(
                kind: .longRunFuel,
                title: String(localized: "Practise your fuelling", comment: "Coach card title"),
                message: String(
                    localized: """
                    \(day)'s \(type) goes past the point where you have to eat on the move. \
                    Start it topped up, then take \(carbs.amount) from about forty-five \
                    minutes in, with \(fluid.amount) of fluid. The long run is where \
                    race-day fuelling gets rehearsed, not where you find out it disagrees \
                    with you.
                    """,
                    comment: "Coach card body for a session long enough to need fuel during it"
                ),
                // No day word: "Tomorrow's" is false the moment the snapshot outlives
                // midnight, and the widget already prints the session's own day label.
                glance: String(
                    localized: "\(carbs.amount) from forty-five minutes in, with \(fluid.amount) of fluid.",
                    comment: "Short coach tip for a long session"
                ),
                tone: .neutral,
                score: 0.6,
                derivation: carbs.derivation
            )

        case .quality:
            let carbs = CoachNutrition.preSessionCarbohydrate(
                bodyMassKg: context.bodyMassKilograms,
                unit: context.unit
            )
            return SmartCoachCard(
                kind: .sessionFuel,
                title: String(localized: "Eat before the hard one", comment: "Coach card title"),
                message: String(
                    localized: """
                    \(day)'s \(type) runs on carbohydrate. Aim for \(carbs.amount) two to \
                    three hours out, or something smaller forty-five minutes before. It is \
                    the difference between hitting the last rep and hanging on through it.
                    """,
                    comment: "Coach card body for a quality session"
                ),
                glance: String(
                    localized: "\(carbs.amount) two to three hours before the session.",
                    comment: "Short coach tip for a quality session"
                ),
                tone: .neutral,
                score: 0.5,
                derivation: carbs.derivation
            )

        case .steady:
            return SmartCoachCard(
                kind: .prep,
                title: String(localized: "Set yourself up for it", comment: "Coach card title"),
                message: String(
                    localized: """
                    \(day)'s \(type) is short enough to run on what you've already eaten. \
                    Lay the kit out the night before, drink a glass of water when you wake, \
                    and have something small and carb-led if you're heading out more than \
                    an hour after breakfast.
                    """,
                    comment: "Coach card body for an ordinary easy run"
                ),
                glance: String(
                    localized: "Short enough to run on what you've already eaten. Lay the kit out.",
                    comment: "Short coach tip for an ordinary easy run"
                ),
                tone: .positive,
                // Low on purpose. This is the card for "nothing needs saying", so almost
                // any real signal should outrank it.
                score: 0.25
            )

        case .nonRun:
            return SmartCoachCard(
                kind: .prep,
                title: String(localized: "Gym day", comment: "Coach card title"),
                message: String(
                    localized: """
                    \(day) is \(type) rather than a run. Eat normally, get some protein in \
                    afterwards, and keep the session honest — the strength work is what \
                    holds your form together late in the long runs.
                    """,
                    comment: "Coach card body for a strength or cross-training day"
                ),
                glance: String(
                    localized: "Gym rather than a run. Eat normally and get protein in afterwards.",
                    comment: "Short coach tip for a strength or cross-training day"
                ),
                tone: .positive,
                score: 0.2
            )
        }
    }

    // MARK: Empty states
    //
    // Four cards for what used to be one. "Your plan starts Monday", "your plan is
    // finished" and "you have no plan" are three different problems, and a rest day is
    // not a problem at all.

    private static func restDayCard(_ context: Context) -> SmartCoachCard {
        let intake = CoachNutrition.recovery(
            bodyMassKg: context.bodyMassKilograms,
            unit: context.unit
        )
        return SmartCoachCard(
            kind: .restDay,
            title: String(localized: "Rest is the training", comment: "Coach card title"),
            message: String(
                localized: """
                Nothing scheduled today. Adaptation happens now rather than during the \
                session, so eat normally instead of cutting back — around \(intake.amount) \
                spread across the day keeps tomorrow's session from starting flat.
                """,
                comment: "Coach card body for a rest day"
            ),
            glance: String(
                localized: "Eat normally rather than cutting back — adaptation happens on the rest day.",
                comment: "Short coach tip for a rest day"
            ),
            tone: .positive,
            score: 0.4,
            derivation: intake.derivation
        )
    }

    private static func planStartsSoonCard(daysUntilStart: Int) -> SmartCoachCard {
        let when: String = {
            switch daysUntilStart {
            case 0:  return String(localized: "today", comment: "When a plan's first day falls")
            case 1:  return String(localized: "tomorrow", comment: "When a plan's first day falls")
            default: return String(localized: "in \(daysUntilStart) days", comment: "When a plan's first day falls")
            }
        }()

        return SmartCoachCard(
            kind: .planStartsSoon,
            title: String(localized: "Your plan starts soon", comment: "Coach card title"),
            message: String(
                localized: """
                Week 1 begins \(when). Use the time for an easy run or two rather than \
                resting up — starting a block already moving beats starting it fresh, and \
                it gives the coach something to calibrate against.
                """,
                comment: "Coach card body before a plan begins"
            ),
            glance: String(
                localized: "Keep ticking over with an easy run before week 1 begins.",
                comment: "Short coach tip before a plan begins"
            ),
            tone: .positive,
            score: 0.55
        )
    }

    private static func planFinishedCard() -> SmartCoachCard {
        SmartCoachCard(
            kind: .planFinished,
            title: String(localized: "That block is done", comment: "Coach card title"),
            message: String(
                localized: """
                Your plan has run its course. Take a few easy days, then build the next \
                block from where you actually finished rather than where the last one \
                started — the Plan tab will size it from your recent running.
                """,
                comment: "Coach card body once a plan has ended"
            ),
            glance: String(
                localized: "Take a few easy days, then build the next block in the Plan tab.",
                comment: "Short coach tip once a plan has ended"
            ),
            tone: .neutral,
            score: 0.6
        )
    }

    private static func noPlanCard() -> SmartCoachCard {
        SmartCoachCard(
            kind: .noPlan,
            title: String(localized: "No plan yet", comment: "Coach card title"),
            message: String(
                localized: """
                Free runs still count, and everything you log feeds the coach. When you \
                want the sessions chosen for you, build a plan in the Plan tab — it only \
                needs a goal and a rough 5K time to start.
                """,
                comment: "Coach card body when there is no training plan"
            ),
            glance: String(
                localized: "Free runs still count. Build a plan when you want the sessions chosen.",
                comment: "Short coach tip when there is no training plan"
            ),
            tone: .neutral,
            score: 0.7
        )
    }

    // MARK: - Helpers

    /// The apparent temperature on the most recent run that carries weather, when it is
    /// recent enough to describe the conditions to expect.
    ///
    /// The app has no forecast — weather is stamped on runs *after* the fact — so this is
    /// the closest thing to one, and the copy that uses it says "your last run out there"
    /// rather than pretending to know what the next will be like.
    static func recentFeelsLike(_ context: Context) -> Double? {
        let cutoff = context.now.addingTimeInterval(-Double(heatLookbackDays) * 86_400)
        return context.recentRuns
            .first { $0.date >= cutoff && $0.weather != nil }?
            .weather?
            .feelsLikeCelsius
    }

    /// How far back a weather reading still describes the conditions to expect.
    static let heatLookbackDays = 10
}
