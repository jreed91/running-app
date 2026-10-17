import Foundation
import SwiftData

/// A read-only copy of the runner's training log that the coach can search while it
/// writes, through Foundation Models tool calling.
///
/// The chat and the run detail read used to get one fixed summary — the newest eight runs
/// — and had to answer from that. "Show my last five easy runs" or "how did my tempos go
/// this month?" needed history the summary did not carry. With this, the model asks for
/// what the question needs and gets the answer as plain lines, in the runner's unit.
///
/// Plain values copied out of SwiftData on the main actor before the request, so the
/// tools that read it can be `Sendable` (Apple's `Tool` requires it) and can never write
/// to the store. `FoundationModelsCoachTools` wraps these queries as tools; nothing here
/// imports `FoundationModels`, so the queries are tested on their own.
struct CoachLookup: Sendable, Equatable {

    struct Run: Sendable, Equatable {
        let date: Date
        let type: WorkoutType
        let distanceMeters: Double
        let durationSeconds: Double
        let averageHeartRate: Double?
        let elevationGainMeters: Double?
        let feel: RunFeel?

        var paceSecondsPerKm: Double? {
            distanceMeters > 0 ? durationSeconds / (distanceMeters / 1_000) : nil
        }
    }

    struct Session: Sendable, Equatable {
        let date: Date
        let type: WorkoutType
        let targetDistanceMeters: Double?
        let isCompleted: Bool
    }

    /// Newest first.
    let runs: [Run]
    /// Oldest first.
    let sessions: [Session]
    let unit: UnitPreference
    let now: Date

    /// The most rows any one answer carries. A tool's output lands in the context window
    /// — the on-device one is small — so an answer is a handful of lines, never a dump.
    static let maximumRows = 10
    /// The most weeks a weekly-totals answer covers, for the same reason.
    static let maximumWeeks = 12
    /// How far back the copy reaches. Half a year covers any question about a training
    /// block, and keeps the copy cheap to build on every send.
    static let historyDays = 180

    private static let runTypes: Set<WorkoutType> = [.easy, .tempo, .interval, .longRun, .race]

    init(runs: [Run], sessions: [Session], unit: UnitPreference, now: Date = Date()) {
        self.runs = runs.sorted { $0.date > $1.date }
        self.sessions = sessions.sorted { $0.date < $1.date }
        self.unit = unit
        self.now = now
    }

    /// Copies `runs` (walks and cross-training dropped) and the plan's run sessions out of
    /// SwiftData. Call it on the main actor, where those models live.
    init(runs: [RunWorkout], scheduled: [ScheduledWorkout], unit: UnitPreference, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(Self.historyDays) * 86_400)
        self.init(
            runs: runs.runsOnly.filter { $0.date >= cutoff }.map {
                Run(
                    date: $0.date,
                    type: $0.workoutType,
                    distanceMeters: $0.distanceMeters,
                    durationSeconds: $0.durationSeconds,
                    averageHeartRate: $0.averageHeartRate,
                    elevationGainMeters: $0.elevationGainMeters,
                    feel: $0.feel
                )
            },
            sessions: scheduled.filter { Self.runTypes.contains($0.workoutType) }.map {
                Session(
                    date: $0.scheduledDate,
                    type: $0.workoutType,
                    targetDistanceMeters: $0.targetDistanceMeters,
                    isCompleted: $0.isCompleted
                )
            },
            unit: unit,
            now: now
        )
    }

    /// Fetches the last ``historyDays`` of runs from `context` and the sessions of `plan`.
    ///
    /// - Parameters:
    ///   - excluding: a run to leave out — the run detail's own run, which its prompt
    ///     already describes in full.
    ///   - now: the moment "how many days back" and "around today" count from. The run
    ///     detail passes the run's own date, so the coach compares a run with what came
    ///     before it, not with weeks the runner had not run yet.
    @MainActor
    static func make(
        context: ModelContext,
        plan: TrainingPlan?,
        unit: UnitPreference,
        excluding: RunWorkout? = nil,
        now: Date = Date()
    ) -> CoachLookup {
        let cutoff = now.addingTimeInterval(-Double(historyDays) * 86_400)
        // Bounded rather than date-filtered in the fetch: runs are few, and a fixed cap
        // keeps a runner with years of history from paying for them on every send.
        let fetched = (try? context.fetch(RunWorkout.runsOnlyDescriptor(fetchLimit: 400))) ?? []
        let runs = fetched.filter { $0.date >= cutoff && $0.date <= now && $0.id != excluding?.id }
        let scheduled = (plan?.weeks ?? []).flatMap { $0.workouts ?? [] }
        return CoachLookup(runs: runs, scheduled: scheduled, unit: unit, now: now)
    }

    // MARK: Queries

    /// The newest runs of `type` (any type when nil) within `withinDays` of now.
    func findRuns(type: WorkoutType?, withinDays: Int, limit: Int) -> String {
        let days = min(max(withinDays, 1), Self.historyDays)
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let matches = runs
            .filter { $0.date >= cutoff && (type == nil || $0.type == type) }
            .prefix(min(max(limit, 1), Self.maximumRows))
        let kind = type.map { "\($0.displayName.lowercased()) runs" } ?? "runs"
        guard !matches.isEmpty else { return "No \(kind) in the last \(days) days." }
        return matches.map(line(for:)).joined(separator: "\n")
    }

    /// Distance and run count for each of the last `weeks` weeks, newest first. Weeks
    /// start on Monday, as everywhere else in the app; the current one is marked as such.
    func weeklyTotals(weeks: Int) -> String {
        let count = min(max(weeks, 1), Self.maximumWeeks)
        let thisWeek = now.startOfWeek
        var lines: [String] = []
        for offset in 0..<count {
            guard let start = Calendar.current.date(byAdding: .day, value: -7 * offset, to: thisWeek),
                  let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { continue }
            let inWeek = runs.filter { $0.date >= start && $0.date < end }
            let distance = inWeek.reduce(0) { $0 + $1.distanceMeters }.distanceString(unit: unit)
            let label = offset == 0 ? "This week so far" : "Week of \(Self.dayLabel(start))"
            lines.append("\(label): \(distance) over \(inWeek.count) \(inWeek.count == 1 ? "run" : "runs")")
        }
        return lines.joined(separator: "\n")
    }

    /// Planned run sessions from `daysBack` before today to `daysAhead` after it.
    func planSessions(daysBack: Int, daysAhead: Int) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -min(max(daysBack, 0), 28), to: today),
              let end = calendar.date(byAdding: .day, value: min(max(daysAhead, 0), 28) + 1, to: today) else {
            return "No plan sessions found."
        }
        let matches = sessions.filter { $0.date >= start && $0.date < end }.prefix(Self.maximumRows)
        guard !matches.isEmpty else { return "No planned runs in that window." }
        return matches.map { session in
            var parts = ["\(Self.dayLabel(session.date)): \(session.type.displayName)"]
            if let target = session.targetDistanceMeters, target > 0 {
                parts.append(target.distanceString(unit: unit))
            }
            if session.isCompleted {
                parts.append("done")
            } else if calendar.startOfDay(for: session.date) < today {
                parts.append("missed")
            } else {
                parts.append("to come")
            }
            return parts.joined(separator: ", ")
        }
        .joined(separator: "\n")
    }

    // MARK: Formatting

    /// One run as the coach reads it: "Tue 14 Oct: Tempo, 8.0 km in 40:00, 5:00 min/km,
    /// avg HR 162, felt hard".
    func line(for run: Run) -> String {
        var parts = [
            "\(Self.dayLabel(run.date)): \(run.type.displayName)",
            "\(run.distanceMeters.distanceString(unit: unit)) in \(run.durationSeconds.durationString)",
        ]
        if let pace = run.paceSecondsPerKm {
            parts.append(pace.paceString(unit: unit))
        }
        if let heartRate = run.averageHeartRate, heartRate > 0 {
            parts.append("avg HR \(Int(heartRate.rounded()))")
        }
        if let feel = run.feel {
            parts.append("felt \(feel.promptName)")
        }
        return parts.joined(separator: ", ")
    }

    /// "Tue 14 Oct", in English like every coach prompt whatever the device language.
    /// A formatter per call, as `GPXExport` does: a shared static one is not `Sendable`.
    static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    // MARK: Instructions

    /// `base`, with ``instructionsNote`` appended when `lookup` brings tools. Without
    /// one the instructions are exactly what they were before tools existed.
    static func instructions(_ base: String, withToolsFor lookup: CoachLookup?) -> String {
        guard lookup != nil else { return base }
        return base + "\n\n" + instructionsNote
    }

    /// Added to a request's instructions only when tools come with it.
    static let instructionsNote = """
    You can look up this runner's training log with tools: findRuns for past runs by kind \
    and how many days back, weeklyTotals for distance per week, and planSessions for the \
    planned runs around today. Use a tool when the answer needs history or plan details \
    that are not already given, and use only what it returns. Never mention the tools.
    """
}
