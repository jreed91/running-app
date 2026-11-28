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
/// The long run gets its own ceiling from the longest run in the same four weeks: plus
/// ``startAllowance`` in week one, growing ``weeklyGrowth`` a week, never under
/// ``longRunFloorKm``. Someone running 25 km a week in 5 km runs would otherwise get a
/// 9.6 km long run on day one, nearly twice anything they have run lately.
///
/// No runs at all in the last ``lookbackWeeks`` means there is nothing to go on: no Health
/// access, a new watch, or a first plan. That is `nil`, and the plan is built as before.
public struct RecentRunningVolume: Equatable, Sendable {
    /// One run, as Health has it.
    public struct Run: Equatable, Sendable {
        public let date: Date
        public let meters: Double

        public init(
            date: Date,
            meters: Double
        ) {
            self.date = date
            self.meters = meters
        }
    }

    /// The window the starting volume is averaged over.
    public static let averageWeeks = 4
    /// How far back any run counts as evidence that Health knows this runner's running.
    public static let lookbackWeeks = 26
    /// Week one may be this much more than the recent weekly average.
    public static let startAllowance = 1.10
    /// Each later week's ceiling grows by this much over the one before.
    public static let weeklyGrowth = 1.10
    /// The smallest starting week, so someone who has barely run still gets real sessions.
    public static let floorKm = 12.0
    /// The smallest long-run ceiling, so a runner with only short runs lately can build.
    public static let longRunFloorKm = 5.0

    /// Average weekly distance over the last ``averageWeeks`` weeks, in km.
    public let averageWeeklyKm: Double
    /// The longest single run in the last ``averageWeeks`` weeks, in km. 0 when there was none.
    public let longestRunKm: Double

    /// - Returns: `nil` when no run of any distance falls in the last ``lookbackWeeks``.
    public init?(runs: [Run], now: Date = Date()) {
        let week: TimeInterval = 7 * 86_400
        let lookbackStart = now.addingTimeInterval(-Double(Self.lookbackWeeks) * week)
        let recent = runs.filter { $0.date <= now && $0.date >= lookbackStart && $0.meters > 0 }
        guard !recent.isEmpty else { return nil }
        let averageStart = now.addingTimeInterval(-Double(Self.averageWeeks) * week)
        let window = recent.filter { $0.date >= averageStart }
        averageWeeklyKm = window.reduce(0.0) { $0 + $1.meters } / 1_000 / Double(Self.averageWeeks)
        longestRunKm = (window.map(\.meters).max() ?? 0) / 1_000
    }

    public init(averageWeeklyKm: Double, longestRunKm: Double) {
        self.averageWeeklyKm = averageWeeklyKm
        self.longestRunKm = longestRunKm
    }

    /// The most a plan built today may ask for in week one, in km.
    public var startingKm: Double {
        max(Self.floorKm, averageWeeklyKm * Self.startAllowance)
    }

    /// The most the plan's week at `weekIndex` (0 for week one) may ask for, in km, before
    /// that week's own cutback or taper reduction.
    public func ceilingKm(weekIndex: Int) -> Double {
        startingKm * pow(Self.weeklyGrowth, Double(max(0, weekIndex)))
    }

    /// The longest the long run in the plan's week at `weekIndex` may be, in km.
    public func longRunCeilingKm(weekIndex: Int) -> Double {
        max(Self.longRunFloorKm, longestRunKm * Self.startAllowance)
            * pow(Self.weeklyGrowth, Double(max(0, weekIndex)))
    }
}
