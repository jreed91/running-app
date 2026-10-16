import Foundation

// MARK: - WidgetSnapshotBuilder

/// Turns the app's models into the ``WidgetSnapshot`` the widget extension renders (B1).
///
/// Pure and stateless, like ``StreakGoalService`` and ``PlanSummaryService``, and for the
/// same reason: this is where the widgets' entire content is decided, and none of it is
/// reachable from a test if it happens inside a view or a `@MainActor` service. Every
/// entry point takes an injectable `now` and `calendar` so week boundaries and "Today"
/// labels can be pinned rather than depending on the machine's clock and time zone.
///
/// It is also the *only* place the widgets' strings are formatted. The snapshot ships
/// finished text (see ``WidgetSnapshot``), so a unit change or a rounding fix lands here
/// once instead of once per widget.
enum WidgetSnapshotBuilder {

    // MARK: Entry point

    static func snapshot(
        plan: TrainingPlan?,
        runs: [RunWorkout],
        profile: UserProfile?,
        weeklyGoalMeters: Double,
        unit: UnitPreference,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WidgetSnapshot {
        // The Home Screen's week, streak and coach tip are all about running, so walks
        // are dropped before any of them is built (N38).
        let runs = runs.runsOnly
        return WidgetSnapshot(
            nextWorkout: nextWorkout(in: plan, unit: unit, now: now, calendar: calendar),
            weekly: weekly(
                runs: runs,
                goalMeters: weeklyGoalMeters,
                unit: unit,
                now: now,
                calendar: calendar
            ),
            streak: streak(runs: runs, now: now, calendar: calendar),
            race: race(plan: plan, profile: profile, now: now, calendar: calendar),
            coachTip: coachTip(
                plan: plan,
                runs: runs,
                profile: profile,
                unit: unit,
                now: now,
                calendar: calendar
            ),
            generatedAt: now
        )
    }

    // MARK: - Coach tip

    /// The winning coaching card, ready for the extension to draw.
    ///
    /// This is the whole of the widget's share of the coach. `SmartCoachCards` reads
    /// scheduled workouts, logged runs, weather and the profile — none of which the
    /// extension can reach — so the selection runs here, in the app, and the extension
    /// gets the answer rather than the inputs. The alternative, a second set of
    /// thresholds compiled into the widget, is exactly the divergence the "finished
    /// strings" rule at the top of `WidgetSnapshot` exists to prevent.
    ///
    /// The **glance** text goes into the snapshot, never `message`: see
    /// `SmartCoachCard.glance` for why a widget-bound string cannot contain a clock.
    static func coachTip(
        plan: TrainingPlan?,
        runs: [RunWorkout],
        profile: UserProfile?,
        unit: UnitPreference,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WidgetSnapshot.CoachTip? {
        // Only the *active* plan, for the same reason `nextWorkout` filters on it: a
        // retired plan keeps its future days, and a Home Screen advising on a plan the
        // runner replaced is worse than one advising on nothing.
        let livePlan = (plan?.isActive == true) ? plan : nil

        let context = SmartCoachCards.Context(
            nextSession: ScheduledDayResolver.upcomingSession(
                onOrAfter: now,
                in: livePlan,
                calendar: calendar
            ),
            recentRuns: runs,
            profile: profile,
            dayState: ScheduledDayResolver.dayState(on: now, in: livePlan, calendar: calendar),
            unit: unit,
            now: now,
            calendar: calendar
        )

        guard let card = SmartCoachCards.cards(context, limit: 1).first else { return nil }
        return WidgetSnapshot.CoachTip(
            title: card.title,
            message: card.glance,
            categoryLabel: card.category.label,
            symbolName: symbolName(for: card.kind),
            tint: tint(for: card.tone),
            expiresAt: card.expiresAt
        )
    }

    /// SF Symbols for the coaching kinds.
    ///
    /// A separate mapping from the dashboard's `StrideIcon` glyphs, because a widget
    /// draws SF Symbols and the app draws its own `Canvas` icon set. Both are presentation
    /// and both live beside the surface that renders them; the *card* stays free of either.
    static func symbolName(for kind: SmartCoachCard.Kind) -> String {
        switch kind {
        case .raceDay, .raceWeek:  return "flag.checkered"
        case .refuel:              return "heart.fill"
        case .longRunFuel:         return "flame.fill"
        case .sessionFuel:         return "flame.fill"
        case .heat:                return "thermometer.sun.fill"
        case .restDay:             return "moon.zzz.fill"
        case .fade:                return "chart.line.downtrend.xyaxis"
        case .polarization:        return "tortoise.fill"
        case .cadence:             return "metronome.fill"
        case .load:                return "mountain.2.fill"
        case .readiness:           return "bed.double.fill"
        case .comeback:            return "figure.run"
        case .prep:                return "checkmark.circle.fill"
        case .planStartsSoon:      return "calendar"
        case .planFinished:        return "flag.fill"
        case .noPlan:              return "plus.circle.fill"
        }
    }

    /// Tone drives the accent, matching the dashboard: a caution reads as one wherever it
    /// came from. `.tempo` is the palette's amber, which is what `Color.warning` is on the
    /// app side — the snapshot's `Tint` is a fixed set of palette names, not a free colour.
    static func tint(for tone: SmartCoachCard.Tone) -> WidgetSnapshot.Tint {
        switch tone {
        case .positive: return .success
        case .neutral:  return .brand
        case .caution:  return .tempo
        }
    }

    // MARK: - Next workout

    /// The session to put on the card.
    ///
    /// Resolved in the order a runner would ask the question:
    ///
    /// 1. Anything still outstanding **today** — including a session from yesterday or
    ///    earlier that the plan has not marked done, which is what the runner is most
    ///    likely to be about to do.
    /// 2. A rest day the plan explicitly schedules for today. Returned as a value rather
    ///    than `nil` so "the plan says rest" cannot render as "there is no plan" (N23).
    /// 3. The next scheduled session in the future.
    ///
    /// Only the **active** plan is consulted. Retired plans keep their future days — they
    /// are preserved as history, not deleted — so without that filter a widget could sit
    /// on the Home Screen advertising a workout from a plan the runner replaced, the same
    /// trap `IntentDataProvider.todaysRun` guards against.
    static func nextWorkout(
        in plan: TrainingPlan?,
        unit: UnitPreference,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WidgetSnapshot.NextWorkout? {
        nextScheduledWorkout(in: plan, now: now, calendar: calendar)
            .map { card(for: $0, unit: unit, now: now, calendar: calendar) }
    }

    /// The ``ScheduledWorkout`` behind ``nextWorkout(in:unit:now:calendar:)``'s card, by
    /// the same three rules. Split out so the watch app's Start button (B3) is built from
    /// the very session the card it sits on describes, rather than from a second lookup
    /// that could pick a different one.
    static func nextScheduledWorkout(
        in plan: TrainingPlan?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduledWorkout? {
        guard let plan, plan.isActive else { return nil }

        let today = calendar.startOfDay(for: now)
        let all = (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .sorted { $0.scheduledDate < $1.scheduledDate }

        let outstanding = all.filter { !$0.isCompleted && $0.workoutType != .rest }

        // 1. Today or overdue — earliest first, so a missed Tuesday shows before Thursday.
        if let due = outstanding.first(where: { calendar.startOfDay(for: $0.scheduledDate) <= today }) {
            return due
        }

        // 2. A genuine rest day.
        let restToday = all.first {
            $0.workoutType == .rest && calendar.isDate($0.scheduledDate, inSameDayAs: today)
        }
        if let restToday {
            return restToday
        }

        // 3. The next thing on the plan.
        return outstanding.first { calendar.startOfDay(for: $0.scheduledDate) > today }
    }

    private static func card(
        for workout: ScheduledWorkout,
        unit: UnitPreference,
        now: Date,
        calendar: Calendar
    ) -> WidgetSnapshot.NextWorkout {
        let isRest = workout.workoutType == .rest
        return WidgetSnapshot.NextWorkout(
            title: workout.workoutType.localizedName,
            detail: isRest ? nil : detail(for: workout, unit: unit),
            paceTarget: isRest ? nil : paceTarget(for: workout, unit: unit),
            note: note(for: workout),
            symbolName: workout.workoutType.icon,
            tint: tint(for: workout.workoutType),
            scheduledDate: workout.scheduledDate,
            isRest: isRest
        )
    }

    /// The headline prescription. Distance when the plan sets one; otherwise nothing —
    /// the title already says "Strength" or "Cross Training", and a widget has no room
    /// to repeat itself.
    private static func detail(for workout: ScheduledWorkout, unit: UnitPreference) -> String? {
        guard let meters = workout.targetDistanceMeters, meters > 0 else { return nil }
        return meters.distanceString(unit: unit)
    }

    private static func paceTarget(for workout: ScheduledWorkout, unit: UnitPreference) -> String? {
        guard let range = workout.targetPaceRange else { return nil }
        let low = range.lowerBound.paceValueString(unit: unit)
        let high = range.upperBound.paceValueString(unit: unit)
        let suffix = unit == .metric ? "/km" : "/mi"
        // An en dash, not a hyphen: this is a range, and it is read aloud as one.
        return low == high ? "\(low) \(suffix)" : "\(low)–\(high) \(suffix)"
    }

    /// The plan's coaching note, cut to something a small widget can hold. Plan notes run
    /// to a couple of sentences; a widget truncating mid-word in the middle of the card
    /// looks broken, whereas one clean sentence reads as intentional.
    static func note(for workout: ScheduledWorkout) -> String? {
        guard let raw = workout.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        // A sentence ends at a full stop followed by a space (or the end of the note), never
        // at a decimal point: "1.9 mi total: warm-up…" must not come out as "1".
        let sentenceEnd = raw.range(of: ". ")?.lowerBound
            ?? (raw.hasSuffix(".") ? raw.index(before: raw.endIndex) : raw.endIndex)
        let firstSentence = String(raw[..<sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = firstSentence.isEmpty ? raw : firstSentence
        return candidate.count <= 80 ? candidate : String(candidate.prefix(79)) + "…"
    }

    /// Mirrors `WorkoutType.color` rather than inventing a second palette mapping, so a
    /// tempo day is the same amber on the Home Screen as it is in the plan.
    private static func tint(for type: WorkoutType) -> WidgetSnapshot.Tint {
        switch type {
        case .easy, .longRun:  return .easy
        case .tempo:           return .tempo
        case .interval, .race: return .interval
        case .strength:        return .brand
        case .rest, .crossTraining, .walk: return .neutral
        }
    }

    // MARK: - Weekly goal

    static func weekly(
        runs: [RunWorkout],
        goalMeters: Double,
        unit: UnitPreference,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WidgetSnapshot.WeeklyGoal {
        let progress = StreakGoalService.weeklyProgress(
            for: runs,
            goalMeters: goalMeters,
            now: now,
            calendar: calendar
        )
        let weekStart = StreakGoalService.startOfWeek(for: now, calendar: calendar)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let runCount = runs.runsOnly.filter { $0.date >= weekStart && $0.date < weekEnd }.count

        let hasGoal = goalMeters > 0
        let statusText: String
        if !hasGoal {
            statusText = String(localized: "Set a weekly goal", comment: "Widget weekly-goal empty state")
        } else if progress.isMet {
            statusText = String(localized: "Weekly goal met", comment: "Widget weekly-goal status")
        } else {
            statusText = String(
                localized: "\(progress.remainingMeters.distanceString(unit: unit)) to go",
                comment: "Widget weekly-goal remaining distance"
            )
        }

        return WidgetSnapshot.WeeklyGoal(
            completedText: progress.completedMeters.distanceString(unit: unit),
            goalText: hasGoal
                ? (goalMeters / 1_000).weeklyDistanceString(unit: unit)
                : String(localized: "No goal", comment: "Widget weekly-goal empty state"),
            statusText: statusText,
            fraction: progress.fraction,
            runCount: runCount,
            isMet: progress.isMet,
            hasGoal: hasGoal
        )
    }

    // MARK: - Streak

    static func streak(
        runs: [RunWorkout],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WidgetSnapshot.Streak {
        let summary = StreakGoalService.streak(for: runs, now: now, calendar: calendar)
        return WidgetSnapshot.Streak(
            current: summary.current,
            longest: summary.longest,
            isActiveToday: summary.isActiveToday
        )
    }

    // MARK: - Race

    /// The goal race, preferring the active plan's copy over the profile's.
    ///
    /// The two can legitimately disagree — a plan keeps the race it was built for while
    /// the profile moves on to the next one — and the countdown belongs to the plan the
    /// runner is actually following. No race date on either (which is the normal state of
    /// a `.maintainFitness` plan) means no countdown, and so does a date already past.
    static func race(
        plan: TrainingPlan?,
        profile: UserProfile?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WidgetSnapshot.RaceCountdown? {
        let activePlan = plan.flatMap { $0.isActive ? $0 : nil }
        let raceDate = activePlan?.raceDate ?? profile?.raceDate
        guard let raceDate else { return nil }

        // Race day itself still counts; the day after it does not. The widget re-checks
        // this at render time (`RaceCountdown.isUpcoming`) — this only keeps a long-past
        // race out of the snapshot in the first place.
        guard WidgetRelativeDay.dayDelta(for: raceDate, asOf: now, calendar: calendar) >= 0 else {
            return nil
        }

        let raceType = activePlan?.targetRace ?? profile?.goalRace
        let fallbackName = raceType?.localizedName
            ?? String(localized: "Race Day", comment: "Widget race countdown fallback name")
        let name = [activePlan?.raceName, profile?.raceName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fallbackName

        let goalSeconds = activePlan?.goalTimeSeconds ?? profile?.goalFinishTime ?? 0

        return WidgetSnapshot.RaceCountdown(
            name: name,
            date: raceDate,
            phaseLabel: phaseLabel(for: activePlan, now: now, calendar: calendar),
            goalTimeText: goalSeconds > 0 ? goalSeconds.durationString : nil
        )
    }

    /// "Peak · Week 12 of 16", from the week the plan is currently in.
    ///
    /// Resolved here rather than through `TrainingPlan.currentWeek`, which reads the wall
    /// clock — a widget snapshot has to be buildable for an arbitrary `now` or none of
    /// this is testable.
    static func phaseLabel(
        for plan: TrainingPlan?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let plan else { return nil }
        let weeks = plan.weeks ?? []
        guard !weeks.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        let current = weeks.first {
            calendar.startOfDay(for: $0.startDate) <= today
                && calendar.startOfDay(for: $0.endDate) >= today
        }
        guard let current else { return nil }
        let phase = current.phase.localizedName
        let position = String(
            localized: "Week \(current.weekNumber) of \(weeks.count)",
            comment: "Widget training-plan position"
        )
        return "\(phase) · \(position)"
    }
}
