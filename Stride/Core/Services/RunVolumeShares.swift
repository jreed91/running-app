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
/// With one or two run days there is no easy run at all, and the remainder folds into the
/// long run so the week still adds up to its trend (M32).
struct RunVolumeShares: Equatable, Sendable {
    /// The long run's share of the week before any remainder is folded into it.
    static let longBase = 0.35
    /// Each quality session's share of the week.
    static let qualityEach = 0.15
    /// The longest an easy run may be, as a fraction of the same week's long run.
    static let easyCapOfLong = 0.8

    /// The long run's share of the week.
    let long: Double
    /// Each easy run's share of the week.
    let easyEach: Double
    /// How many easy runs the week has.
    let easySlots: Int
    /// How many quality sessions the week has.
    let qualitySlots: Int

    /// - Parameters:
    ///   - runDays: run days in the week; the last is the long run.
    ///   - qualitySlots: quality sessions among them, already capped.
    init(runDays: Int, qualitySlots: Int) {
        let quality = max(0, min(qualitySlots, runDays - 1))
        let easySlots = max(0, runDays - quality - 1)
        let remainder = max(0.0, 1.0 - Self.longBase - Self.qualityEach * Double(quality))
        if easySlots == 0 {
            long = Self.longBase + remainder
            easyEach = 0
        } else {
            long = Self.longBase
            easyEach = min(remainder / Double(easySlots), Self.longBase * Self.easyCapOfLong)
        }
        self.easySlots = easySlots
        self.qualitySlots = quality
    }

    /// What the week's runs add up to, as a fraction of its trend volume. 1 except where the
    /// easy-run cap held volume back.
    var scheduledFraction: Double {
        long + easyEach * Double(easySlots) + Self.qualityEach * Double(qualitySlots)
    }
}
