import Foundation

// MARK: - Facts

/// What the app knows about one training week, worked out before any model sees it.
///
/// Every figure the Progress tab's "week in review" says comes from here, so the card
/// reads the same with or without Apple Intelligence: the model only puts these facts
/// into a coach's words, and ``WeekReview/validated(_:for:unit:)`` throws its wording
/// away if it carries a number that is not one of them.
struct WeekReviewFacts: Equatable, Sendable {
    /// Monday of the reviewed week, as `Date.startOfWeek` defines it.
    let weekStart: Date
    /// True while the week is still running, so "so far" belongs in every sentence.
    let isCurrentWeek: Bool
    /// Days of the week still to come, today excluded. Zero for a finished week.
    let daysLeft: Int

    let runCount: Int
    let totalMeters: Double
    let longestRunMeters: Double
    let totalSeconds: Double
    /// The harder sessions the runner did, by type, in the order they ran them.
    let keySessions: [WorkoutType]

    /// Run sessions the active plan scheduled in the week. Zero without a plan.
    let plannedSessions: Int
    let completedSessions: Int
    /// Planned sessions still ahead this week. Zero for a finished week.
    let upcomingSessions: Int
    /// The plan's distance for the week, summed from its sessions; nil when it set none.
    let plannedMeters: Double?

    /// The runner's average weekly distance over the four weeks before this one; nil
    /// when fewer than two of them had a run, which is too little to call "usual".
    let usualWeeklyMeters: Double?

    /// The runner's rounded average answer to "how did that feel?"; nil when unrated.
    let averageFeel: RunFeel?
    /// Easy runs the runner rated hard or very hard — the earliest sign of fatigue.
    let easyRunsFeltHard: Int

    var hasPlan: Bool { plannedSessions > 0 }

    /// Distance against the plan, as a whole percentage; nil without a planned distance.
    var percentOfPlan: Int? {
        guard let plannedMeters, plannedMeters > 0 else { return nil }
        return Int((totalMeters / plannedMeters * 100).rounded())
    }
}

// MARK: - Model output

/// The week review as Apple's model wrote it, before anything has checked it. Plain
/// strings so `OnDeviceCoachGenerating` can hand it across without `FoundationModels`.
struct WeekReviewDraft: Sendable, Equatable {
    let headline: String
    let summary: String
    let nextFocus: String
}

/// A model-written review that passed ``WeekReview/validated(_:for:unit:)``, bound to the
/// facts it was written from so it is never drawn over a different week's numbers.
struct WeekReviewWording: Codable, Sendable, Equatable {
    let headline: String
    let summary: String
    let nextFocus: String
    /// ``WeekReview/prompt(for:unit:)`` at the time of writing.
    let source: String
}

// MARK: - WeekReview

/// The Progress tab's "this week" card: a short read on the week, written by Apple
/// Intelligence from facts the app computed.
///
/// Built the way `CoachTipRewriter` is, for the same reason. The arithmetic stays
/// deterministic and tested; the model writes the words; a draft that carries any number
/// the facts do not is dropped. So the worst a bad generation can do is leave the card on
/// its own plain sentence, which is also what shows while the model writes, with AI Coach
/// off, and on a device without Apple Intelligence.
///
/// Pure: the generation itself is `AICoachService.writeWeekReview(for:unit:provider:)`.
enum WeekReview {

    /// Longest accepted fields: room for two or three sentences, not a takeover.
    static let maximumHeadlineLength = 60
    static let maximumSummaryLength = 360
    static let maximumFocusLength = 160

    /// Weeks averaged for the runner's usual week, and how many of them need a run.
    static let usualWindowWeeks = 4
    static let usualMinimumActiveWeeks = 2

    private static let keySessionTypes: Set<WorkoutType> = [.tempo, .interval, .longRun, .race]
    private static let plannedRunTypes: Set<WorkoutType> = [.easy, .tempo, .interval, .longRun, .race]

    // MARK: Facts

    /// The week worth reviewing: this one once it has a run, otherwise last week when it
    /// had one, otherwise nothing — a card about zero runs tells the runner nothing.
    ///
    /// - Parameters:
    ///   - runs: the runner's runs in any order; walks and cross-training are ignored.
    ///   - scheduled: the active plan's sessions, any range; only the week's are read.
    static func facts(
        runs: [RunWorkout],
        scheduled: [ScheduledWorkout],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WeekReviewFacts? {
        let running = runs.runsOnly
        let thisWeek = now.startOfWeek
        let candidates = [thisWeek, calendar.date(byAdding: .day, value: -7, to: thisWeek)].compactMap { $0 }
        for weekStart in candidates {
            guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { continue }
            let inWeek = running
                .filter { $0.date >= weekStart && $0.date < weekEnd && $0.date <= now }
                .sorted { $0.date < $1.date }
            guard !inWeek.isEmpty else { continue }
            return facts(
                weekRuns: inWeek,
                allRuns: running,
                scheduled: scheduled,
                weekStart: weekStart,
                weekEnd: weekEnd,
                now: now,
                calendar: calendar
            )
        }
        return nil
    }

    private static func facts(
        weekRuns: [RunWorkout],
        allRuns: [RunWorkout],
        scheduled: [ScheduledWorkout],
        weekStart: Date,
        weekEnd: Date,
        now: Date,
        calendar: Calendar
    ) -> WeekReviewFacts {
        let isCurrent = now < weekEnd
        let today = calendar.startOfDay(for: now)
        let daysLeft = isCurrent
            ? max((calendar.dateComponents([.day], from: today, to: weekEnd).day ?? 1) - 1, 0)
            : 0

        let planned = scheduled.filter {
            $0.scheduledDate >= weekStart && $0.scheduledDate < weekEnd
                && plannedRunTypes.contains($0.workoutType)
        }
        let completed = planned.filter(\.isCompleted).count
        let upcoming = isCurrent
            ? planned.filter { !$0.isCompleted && calendar.startOfDay(for: $0.scheduledDate) > today }.count
            : 0
        let plannedMeters = planned.compactMap(\.targetDistanceMeters).reduce(0, +)

        let feels = weekRuns.compactMap(\.feel)
        let averageFeel = feels.isEmpty
            ? nil
            : RunFeel(rawValue: Int((Double(feels.map(\.rawValue).reduce(0, +)) / Double(feels.count)).rounded()))
        let easyFeltHard = weekRuns.filter {
            $0.workoutType == .easy && ($0.feel == .hard || $0.feel == .veryHard)
        }.count

        return WeekReviewFacts(
            weekStart: weekStart,
            isCurrentWeek: isCurrent,
            daysLeft: daysLeft,
            runCount: weekRuns.count,
            totalMeters: weekRuns.reduce(0) { $0 + $1.distanceMeters },
            longestRunMeters: weekRuns.map(\.distanceMeters).max() ?? 0,
            totalSeconds: weekRuns.reduce(0) { $0 + $1.durationSeconds },
            keySessions: weekRuns.map(\.workoutType).filter { keySessionTypes.contains($0) },
            plannedSessions: planned.count,
            completedSessions: completed,
            upcomingSessions: upcoming,
            plannedMeters: plannedMeters > 0 ? plannedMeters : nil,
            usualWeeklyMeters: usualWeeklyMeters(before: weekStart, runs: allRuns, calendar: calendar),
            averageFeel: averageFeel,
            easyRunsFeltHard: easyFeltHard
        )
    }

    /// Average distance of the ``usualWindowWeeks`` weeks before `weekStart`, empty weeks
    /// counted as zero — a week off is part of a runner's usual — but only once at least
    /// ``usualMinimumActiveWeeks`` of them had a run.
    static func usualWeeklyMeters(
        before weekStart: Date,
        runs: [RunWorkout],
        calendar: Calendar = .current
    ) -> Double? {
        var totals: [Double] = []
        for offset in 1...usualWindowWeeks {
            guard let start = calendar.date(byAdding: .day, value: -7 * offset, to: weekStart),
                  let end = calendar.date(byAdding: .day, value: 7, to: start) else { continue }
            totals.append(
                runs.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.distanceMeters }
            )
        }
        guard totals.filter({ $0 > 0 }).count >= usualMinimumActiveWeeks else { return nil }
        return totals.reduce(0, +) / Double(totals.count)
    }

    // MARK: Plain copy

    /// The card's own headline, shown whenever there is no checked wording.
    static func plainHeadline(for facts: WeekReviewFacts, unit: UnitPreference) -> String {
        let distance = facts.totalMeters.distanceString(unit: unit)
        if facts.runCount == 1 {
            return String(localized: "1 run · \(distance)", comment: "Week review headline: one run and its distance")
        }
        return String(
            localized: "\(facts.runCount) runs · \(distance)",
            comment: "Week review headline: run count and distance"
        )
    }

    /// The card's own sentence: against the plan when there is one, against the runner's
    /// usual week otherwise, and the longest run when there is neither.
    static func plainSummary(for facts: WeekReviewFacts, unit: UnitPreference) -> String {
        if let percent = facts.percentOfPlan, let planned = facts.plannedMeters {
            let plannedText = planned.distanceString(unit: unit)
            let done = facts.completedSessions
            let total = facts.plannedSessions
            return String(
                localized: "\(percent)% of the \(plannedText) planned, \(done) of \(total) sessions done.",
                comment: "Week review: distance against the plan and sessions done"
            )
        }
        if facts.hasPlan {
            return String(
                localized: "\(facts.completedSessions) of \(facts.plannedSessions) planned sessions done.",
                comment: "Week review: planned sessions done"
            )
        }
        if let usual = facts.usualWeeklyMeters {
            let usualText = usual.distanceString(unit: unit)
            return String(
                localized: "Your usual week is about \(usualText).",
                comment: "Week review: the runner's usual weekly distance"
            )
        }
        let longest = facts.longestRunMeters.distanceString(unit: unit)
        return String(localized: "Longest run \(longest).", comment: "Week review: the week's longest run")
    }

    // MARK: Prompt

    static let instructions = """
    You are Stride's running coach, writing a short review of the runner's training week \
    for their Progress screen.

    The app has already worked out every fact about the week. Write like a coach talking \
    to this runner: say "you", use everyday words, keep each sentence to one idea, and be \
    honest but encouraging. Say what went well, what to watch, and one thing to focus on \
    next. If the week is still under way, talk about it as a week in progress.

    Use only the facts given. Copy any number, distance or unit exactly as it is written, \
    and write no other numbers: do not add, subtract, round or convert them. Do not invent \
    runs, paces, heart rates or plans. Write paces and times as given, never as a count \
    of seconds.

    No lists, headings or emoji. Give no medical advice, and never mention that you are \
    an AI.
    """

    /// The facts as the model reads them, one per line, in English like every coach
    /// prompt. Doubles as the key a wording is bound to (``WeekReviewWording/source``), so
    /// any change to the week — a new run, a feel rating, a plan edit — asks again.
    static func prompt(for facts: WeekReviewFacts, unit: UnitPreference) -> String {
        var lines: [String] = []
        lines.append(facts.isCurrentWeek
            ? "Week: this week, still under way, \(facts.daysLeft) days left"
            : "Week: last week, finished")
        lines.append("Runs: \(facts.runCount)")
        lines.append("Distance: \(facts.totalMeters.distanceString(unit: unit))")
        lines.append("Time running: \(facts.totalSeconds.durationString)")
        lines.append("Longest run: \(facts.longestRunMeters.distanceString(unit: unit))")
        if facts.keySessions.isEmpty {
            lines.append("Harder sessions: none")
        } else {
            lines.append("Harder sessions: \(facts.keySessions.map(\.displayName).joined(separator: ", "))")
        }

        if facts.hasPlan {
            lines.append("Planned sessions: \(facts.plannedSessions), done: \(facts.completedSessions)")
            if facts.isCurrentWeek {
                lines.append("Planned sessions still to come this week: \(facts.upcomingSessions)")
            }
            if let planned = facts.plannedMeters, let percent = facts.percentOfPlan {
                lines.append("Planned distance: \(planned.distanceString(unit: unit)) (\(percent)% done)")
            }
        } else {
            lines.append("Training plan: none")
        }

        if let usual = facts.usualWeeklyMeters {
            lines.append("Usual weekly distance over the last month: \(usual.distanceString(unit: unit))")
        }
        if let feel = facts.averageFeel {
            lines.append("How runs felt on average: \(feel.promptName)")
        }
        if facts.easyRunsFeltHard > 0 {
            lines.append("Easy runs that felt hard: \(facts.easyRunsFeltHard)")
        }

        return """
        Review this training week.

        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: Validation

    /// The draft when it is safe to show, else nil.
    ///
    /// Dropped when a field is blank or overlong, or when any field carries a number the
    /// prompt does not. Unlike the tips' check this is a subset test, not an equality one:
    /// a review rightly quotes a few of the facts and leaves the rest, but it may never
    /// write a figure the app did not compute — "you're 6 km short" is arithmetic the
    /// model was told not to do, and is exactly the kind it gets wrong.
    static func validated(
        _ draft: WeekReviewDraft,
        for facts: WeekReviewFacts,
        unit: UnitPreference
    ) -> WeekReviewWording? {
        let headline = draft.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let focus = draft.nextFocus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty, headline.count <= maximumHeadlineLength,
              !summary.isEmpty, summary.count <= maximumSummaryLength,
              !focus.isEmpty, focus.count <= maximumFocusLength else { return nil }

        let source = prompt(for: facts, unit: unit)
        let allowed = normalizedNumbers(in: source)
        let written = normalizedNumbers(in: headline)
            .union(normalizedNumbers(in: summary))
            .union(normalizedNumbers(in: focus))
        guard written.isSubset(of: allowed) else { return nil }

        return WeekReviewWording(headline: headline, summary: summary, nextFocus: focus, source: source)
    }

    /// Digit-written numbers in `text`, read with `CoachTipRewriter.numbers(in:)` and
    /// then compared by value, so "24 km" matches a fact of "24.0 km". Times and paces
    /// ("5:12", "1:02:40") and anything that is not a plain decimal stay as written.
    static func normalizedNumbers(in text: String) -> Set<String> {
        Set(CoachTipRewriter.numbers(in: text).map { number in
            guard !number.contains(":"),
                  let value = Double(number.replacingOccurrences(of: ",", with: "")) else { return number }
            return String(format: "%g", value)
        })
    }
}
