import Foundation

/// How a week's running volume is split between the long run, the quality sessions and the
/// easy runs, as fractions of the week's trend volume.
///
/// The long run takes 35% and each quality session 15%. The easy runs share what is left,
/// but no easy run may be longer than ``easyCapOfLong`` of the long run. On three run days
/// there is only one easy run, and an even share of the remainder made it half the week:
/// longer than the long run itself (a 40 km week was a 14 km long run and a 20 km easy run).
/// The volume that cap holds back is not moved anywhere, so such a week schedules less than
/// its trend, which ``scheduledFraction`` reports.
///
/// The long run can also be capped from outside (`longCap`): for a runner whose recent
/// longest run is well short of a third of their week (`RecentRunningVolume`). A capped
/// long run caps the easy runs under it in turn, and no quality session is longer than it.
///
/// With one or two run days there is no easy run at all, and the long run keeps its usual
/// share: the rest of the week's trend is not run. It used to fold into the long run so the
/// week still added up to its trend (M32), which on one run day made the long run the whole
/// week: a runner with an 8 mile goal was asked for a single 26 mile run.
///
/// ``longRunMaxKm(raceDistanceKm:)`` is the long run's ceiling from the goal itself, applied
/// through `longCap` with the runner's own (`RecentRunningVolume`).
public struct RunVolumeShares: Equatable, Sendable {
    /// The long run's share of the week.
    public static let longBase = 0.35
    /// Each quality session's share of the week, before the long run caps it.
    public static let qualityBase = 0.15
    /// The longest an easy run may be, as a fraction of the same week's long run.
    public static let easyCapOfLong = 0.8

    /// The long run's share of the week.
    public let long: Double
    /// Each quality session's share of the week.
    public let qualityEach: Double
    /// Each easy run's share of the week.
    public let easyEach: Double
    /// How many easy runs the week has.
    public let easySlots: Int
    /// How many quality sessions the week has.
    public let qualitySlots: Int

    /// - Parameters:
    ///   - runDays: run days in the week; the last is the long run.
    ///   - qualitySlots: quality sessions among them, already capped.
    ///   - longCap: the most the long run may be, as a fraction of the week. No cap by default.
    public init(runDays: Int, qualitySlots: Int, longCap: Double = .infinity) {
        let quality = max(0, min(qualitySlots, runDays - 1))
        let easySlots = max(0, runDays - quality - 1)
        let remainder = max(0.0, 1.0 - Self.longBase - Self.qualityBase * Double(quality))
        let cap = max(0, longCap)
        if easySlots == 0 {
            long = min(Self.longBase, cap)
            easyEach = 0
        } else {
            let capped = min(Self.longBase, cap)
            long = capped
            easyEach = min(remainder / Double(easySlots), capped * Self.easyCapOfLong)
        }
        qualityEach = min(Self.qualityBase, long)
        self.easySlots = easySlots
        self.qualitySlots = quality
    }

    /// The longest a long run should ever be for a goal of `raceDistanceKm`, in km: 10 km
    /// plus 60% of the race. 13 km for a 5K, 16 km for a 10K, about 11 miles for an 8 mile
    /// race, 23 km for a half and 35 km for a marathon, in line with common plans' peaks.
    public static func longRunMaxKm(raceDistanceKm: Double) -> Double {
        10 + 0.6 * max(0, raceDistanceKm)
    }

    /// What the week's runs add up to, as a fraction of its trend volume. 1 except where a
    /// cap held volume back, or there are too few run days to hold it.
    public var scheduledFraction: Double {
        long + easyEach * Double(easySlots) + qualityEach * Double(qualitySlots)
    }
}
