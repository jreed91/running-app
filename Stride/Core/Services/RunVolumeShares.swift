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
/// With one or two run days there is no easy run at all, and the remainder folds into the
/// long run so the week still adds up to its trend (M32), unless `longCap` stops it.
struct RunVolumeShares: Equatable, Sendable {
    /// The long run's share of the week before any remainder is folded into it.
    static let longBase = 0.35
    /// Each quality session's share of the week, before the long run caps it.
    static let qualityBase = 0.15
    /// The longest an easy run may be, as a fraction of the same week's long run.
    static let easyCapOfLong = 0.8

    /// The long run's share of the week.
    let long: Double
    /// Each quality session's share of the week.
    let qualityEach: Double
    /// Each easy run's share of the week.
    let easyEach: Double
    /// How many easy runs the week has.
    let easySlots: Int
    /// How many quality sessions the week has.
    let qualitySlots: Int

    /// - Parameters:
    ///   - runDays: run days in the week; the last is the long run.
    ///   - qualitySlots: quality sessions among them, already capped.
    ///   - longCap: the most the long run may be, as a fraction of the week. No cap by default.
    init(runDays: Int, qualitySlots: Int, longCap: Double = .infinity) {
        let quality = max(0, min(qualitySlots, runDays - 1))
        let easySlots = max(0, runDays - quality - 1)
        let remainder = max(0.0, 1.0 - Self.longBase - Self.qualityBase * Double(quality))
        let cap = max(0, longCap)
        if easySlots == 0 {
            long = min(Self.longBase + remainder, cap)
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

    /// What the week's runs add up to, as a fraction of its trend volume. 1 except where a
    /// cap held volume back.
    var scheduledFraction: Double {
        long + easyEach * Double(easySlots) + qualityEach * Double(qualitySlots)
    }
}
