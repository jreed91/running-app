import Foundation

// MARK: - PlanRebuildWindow

/// How long a rebuilt plan should be.
///
/// "Rebuild my plan" replaces the block a runner has fallen behind on with a fresh one
/// starting today. A plan built around a race keeps the race date and needs no
/// arithmetic — the finish line fixes the length. An open-ended plan has only its old
/// end date to go on, so the new block runs for whatever is left of it.
///
/// `AppContainer` did this inline (D2), which put calendar arithmetic on the DI
/// container with no test home — the same reason N6's race clamp had none until
/// `MissedWorkoutShift` moved out.
enum PlanRebuildWindow {

    /// Whole weeks to generate for a rebuild running from `startDate` to `endDate`.
    ///
    /// Measured start-of-day to start-of-day so a plan ending at 18:00 today counts as
    /// covering today, not as a fraction of a day. The span is **inclusive** of both
    /// ends — a plan ending six days from now has seven days left, which is one week —
    /// and rounds up, so a partial week still gets generated rather than being dropped.
    ///
    /// - Returns: At least ``minimumWeeks``. An end date already in the past means the
    ///   old block is spent; the runner asked for a plan, so they get the shortest real
    ///   one rather than an empty one.
    static func remainingWeeks(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar = .current
    ) -> Int {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        let remainingDays = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        let weeks = Int(ceil(Double(remainingDays + 1) / Double(daysPerWeek)))
        return max(minimumWeeks, weeks)
    }

    /// The floor on a rebuilt plan's length.
    static let minimumWeeks = 1

    private static let daysPerWeek = 7
}
