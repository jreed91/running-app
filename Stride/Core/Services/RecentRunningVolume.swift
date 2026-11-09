import Foundation

/// What the runner has actually been running lately, read from Health when a plan is built,
/// and the weekly ceiling that puts on the new plan.
///
/// Without it a plan's first week comes only from the fitness level picked in setup. A
/// "Recreational" runner coming back from six weeks of barely running got the same 40 km
/// first week as one who never stopped. With it, week one starts from the last four weeks'
/// average plus ``startAllowance`` (never below ``floorKm``), and each week after may grow
/// by at most ``weeklyGrowth`` until it meets the plan's usual volume, after which the plan
/// is exactly what it was. A runner already doing more than the plan asks is unaffected.
///
/// No runs at all in the last ``lookbackWeeks`` means there is nothing to go on: no Health
/// access, a new watch, or a first plan. That is `nil`, and the plan is built as before.
struct RecentRunningVolume: Equatable, Sendable {
    /// One run, as Health has it.
    struct Run: Equatable, Sendable {
        let date: Date
        let meters: Double
    }

    /// The window the starting volume is averaged over.
    static let averageWeeks = 4
    /// How far back any run counts as evidence that Health knows this runner's running.
    static let lookbackWeeks = 26
    /// Week one may be this much more than the recent weekly average.
    static let startAllowance = 1.10
    /// Each later week's ceiling grows by this much over the one before.
    static let weeklyGrowth = 1.10
    /// The smallest starting week, so someone who has barely run still gets real sessions.
    static let floorKm = 12.0

    /// Average weekly distance over the last ``averageWeeks`` weeks, in km.
    let averageWeeklyKm: Double

    /// - Returns: `nil` when no run of any distance falls in the last ``lookbackWeeks``.
    init?(runs: [Run], now: Date = Date()) {
        let week: TimeInterval = 7 * 86_400
        let lookbackStart = now.addingTimeInterval(-Double(Self.lookbackWeeks) * week)
        let recent = runs.filter { $0.date <= now && $0.date >= lookbackStart && $0.meters > 0 }
        guard !recent.isEmpty else { return nil }
        let averageStart = now.addingTimeInterval(-Double(Self.averageWeeks) * week)
        let meters = recent
            .filter { $0.date >= averageStart }
            .reduce(0.0) { $0 + $1.meters }
        averageWeeklyKm = meters / 1_000 / Double(Self.averageWeeks)
    }

    init(averageWeeklyKm: Double) {
        self.averageWeeklyKm = averageWeeklyKm
    }

    /// The most a plan built today may ask for in week one, in km.
    var startingKm: Double {
        max(Self.floorKm, averageWeeklyKm * Self.startAllowance)
    }

    /// The most the plan's week at `weekIndex` (0 for week one) may ask for, in km, before
    /// that week's own cutback or taper reduction.
    func ceilingKm(weekIndex: Int) -> Double {
        startingKm * pow(Self.weeklyGrowth, Double(max(0, weekIndex)))
    }
}
