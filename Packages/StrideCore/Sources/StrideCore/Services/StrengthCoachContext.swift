import Foundation

// MARK: - StrengthCoachContext

/// Strength training as the coach chat's context block, so the coach can answer "should I
/// lift before my long run?" knowing what was lifted and when.
///
/// Short on purpose: the chat prompt has a budget, and the coach needs the last session's
/// shape and whether the week's planned sessions are getting done, not every set.
public enum StrengthCoachContext {

    /// Lifts named from the last session, at most.
    public static let maxLifts = 4

    /// Sessions older than this are not "recent" enough to describe.
    public static let lookbackDays = 28

    public static func summary(
        sessions: [StrengthSessionLog],
        plannedThisWeek: Int,
        doneThisWeek: Int,
        unit: UnitPreference,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var lines = ["Strength training:"]

        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        let recent = sessions.filter { $0.date >= cutoff && $0.date <= now }.sorted { $0.date > $1.date }

        if let last = recent.first {
            let days = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: last.date), to: calendar.startOfDay(for: now)
            ).day ?? 0
            let when = days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
            let working = last.sets.filter { !$0.skipped }
            // Stride never saves a session without sets, so one with none was recorded on
            // the Watch or in another app and imported from Apple Health. "0 sets" would
            // read as a session that didn't happen.
            guard !last.sets.isEmpty else {
                let minutes = Int((last.durationSeconds / 60).rounded())
                let length = minutes > 0 ? "\(minutes) min, " : ""
                lines.append("Last session: \(when), \(length)recorded outside Stride (no sets logged).")
                lines.append("Sessions in the last \(lookbackDays) days: \(recent.count).")
                return finish(lines, plannedThisWeek: plannedThisWeek, doneThisWeek: doneThisWeek)
            }
            var line = "Last session: \(when), \(working.count) sets"

            // Lifts in the order they were done, each as last time's top sets.
            var order: [String] = []
            for set in working where !order.contains(set.exerciseName) {
                order.append(set.exerciseName)
            }
            let lifts = order.prefix(maxLifts).map { name -> String in
                let performance = ExercisePerformance(
                    date: last.date,
                    sets: working.filter { $0.exerciseName == name }
                )
                return "\(name) \(StrengthProgression.summary(of: performance, unit: unit))"
            }
            if !lifts.isEmpty {
                line += ": " + lifts.joined(separator: "; ")
            }
            lines.append(line + ".")
            lines.append("Sessions in the last \(lookbackDays) days: \(recent.count).")
        } else {
            lines.append("No strength sessions in the last \(lookbackDays) days.")
        }

        return finish(lines, plannedThisWeek: plannedThisWeek, doneThisWeek: doneThisWeek)
    }

    private static func finish(_ lines: [String], plannedThisWeek: Int, doneThisWeek: Int) -> String {
        var lines = lines
        if plannedThisWeek > 0 {
            lines.append("This week: \(doneThisWeek) of \(plannedThisWeek) planned strength sessions done.")
        }
        return lines.joined(separator: "\n")
    }
}
