import Foundation

// MARK: - NextUpBriefing

/// Everything the dashboard's "Up next" card says about the plan's next session.
///
/// The card used to be a one-line label built inline in `DashboardView` — workout type,
/// scheduled date, chevron — and it only appeared on days the plan left empty. That made
/// the one fact a runner opens the app for ("what am I doing next, and how far is it?")
/// the fact the screen was least likely to be showing.
///
/// Pure and stateless like ``WidgetSnapshotBuilder``, and for the same reason: this is
/// where the card's whole content is decided, and none of it is reachable from a test if
/// it happens inside a view body. Every entry point takes an injectable `now` and
/// `calendar` so "Today" and "Tomorrow" can be pinned rather than depending on the
/// machine's clock.
struct NextUpBriefing: Equatable, Sendable {
    /// The session's name — "Long Run", "Tempo".
    let title: String
    /// How far away it is in words: "Today", "Tomorrow", "Thursday".
    let dayPhrase: String
    /// The calendar date, always shown alongside `dayPhrase` so "Thursday" is never
    /// ambiguous between this week and next.
    let dateText: String
    /// Target distance, in the runner's unit. `nil` when the plan sets none.
    let distanceText: String?
    /// Target pace range, in the runner's unit.
    let paceText: String?
    /// Estimated moving time, derived from the workout's structure or its distance and
    /// pace. `nil` when neither is known.
    let durationText: String?
    /// The plan's coaching note, cut to one sentence.
    let note: String?
    let isToday: Bool

    // MARK: Building

    static func make(
        for workout: ScheduledWorkout,
        unit: UnitPreference,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> NextUpBriefing {
        NextUpBriefing(
            title: workout.workoutType.localizedName,
            dayPhrase: dayPhrase(for: workout.scheduledDate, now: now, calendar: calendar),
            dateText: workout.scheduledDate.formatted(.dateTime.weekday(.abbreviated).month().day()),
            distanceText: distanceText(for: workout, unit: unit),
            paceText: paceText(for: workout, unit: unit),
            durationText: estimatedDurationSeconds(for: workout).flatMap(approximateDurationText),
            // Reuses the widget's note trimming rather than growing a second one: both
            // want the plan's first sentence and neither has room for the paragraph.
            note: WidgetSnapshotBuilder.note(for: workout),
            isToday: calendar.isDateInToday(workout.scheduledDate)
        )
    }

    // MARK: Pieces

    /// How a session's date is named in coach copy.
    ///
    /// "Today" and "Tomorrow" inside the next two days, the bare weekday within the week
    /// after that, and an abbreviated date beyond it — past which "Tuesday" stops meaning
    /// anything without a calendar in the other hand.
    static func dayPhrase(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDateInToday(date) {
            return String(localized: "Today", comment: "How far away a scheduled session is")
        }
        if calendar.isDateInTomorrow(date) {
            return String(localized: "Tomorrow", comment: "How far away a scheduled session is")
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if (0...6).contains(days) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month().day())
    }

    static func distanceText(for workout: ScheduledWorkout, unit: UnitPreference) -> String? {
        guard let meters = workout.targetDistanceMeters, meters > 0 else { return nil }
        return meters.distanceString(unit: unit)
    }

    /// The target pace range, formatted the way the widget's card formats it — an en
    /// dash, because this is a range and it is read aloud as one.
    static func paceText(for workout: ScheduledWorkout, unit: UnitPreference) -> String? {
        guard let range = workout.targetPaceRange else { return nil }
        let low = range.lowerBound.paceValueString(unit: unit)
        let high = range.upperBound.paceValueString(unit: unit)
        let suffix = unit == .metric ? "/km" : "/mi"
        return low == high ? "\(low) \(suffix)" : "\(low)–\(high) \(suffix)"
    }

    /// How long the session is expected to take.
    ///
    /// The generated structure's own estimate wins where there is one — it accounts for
    /// warm-up, recoveries and cool-down, which distance × pace does not. Otherwise the
    /// prescription is multiplied out, using the middle of the target band so a wide
    /// range doesn't read as its optimistic end.
    ///
    /// Shared with ``SmartCoachCards``, which needs the same number to decide whether a
    /// session is long enough to need fuelling during it.
    static func estimatedDurationSeconds(for workout: ScheduledWorkout) -> Double? {
        if let structure = workout.workoutStructure,
           structure.totalEstimatedDurationSeconds > 0 {
            return structure.totalEstimatedDurationSeconds
        }
        guard let meters = workout.targetDistanceMeters, meters > 0,
              let pace = midTargetPaceSecondsPerKm(for: workout), pace > 0 else { return nil }
        return meters / 1_000 * pace
    }

    /// The middle of the target pace band, or whichever single bound the plan set.
    static func midTargetPaceSecondsPerKm(for workout: ScheduledWorkout) -> Double? {
        if let range = workout.targetPaceRange {
            return (range.lowerBound + range.upperBound) / 2
        }
        return workout.targetPaceLowerBound ?? workout.targetPaceUpperBound
    }

    /// A rounded, tilde-prefixed duration: "~48 min", "~1 h 25 min".
    ///
    /// Deliberately coarse. This is an estimate built out of a pace *range*, and printing
    /// it as "1:24:30" would claim a precision the number does not have.
    static func approximateDurationText(seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 60 else { return nil }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 {
            return String(
                localized: "~\(totalMinutes) min",
                comment: "Estimated session duration under an hour"
            )
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return String(localized: "~\(hours) h", comment: "Estimated session duration in whole hours")
        }
        return String(
            localized: "~\(hours) h \(minutes) min",
            comment: "Estimated session duration in hours and minutes"
        )
    }
}
