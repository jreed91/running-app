import Foundation

// MARK: - CoachBaseline

/// A threshold that starts as published advice and becomes the runner's own.
///
/// The coaching rules began with global constants — 165 steps a minute, an 8% gap between
/// easy and hard pace — which is the only thing that can be said to someone with no
/// history. It is also, once they have one, the wrong question: a runner who has always
/// turned over at 158 is not doing anything wrong at 158, and one who normally sits at
/// 182 has changed something real by dropping to 170. Both are invisible to a fixed line
/// and obvious against their own.
///
/// So each baseline carries both, and switches when there is enough history to have
/// earned the switch. `sampleFloor` is where that happens, and it is deliberately the
/// same everywhere: a threshold that quietly personalised at three samples in one rule
/// and twelve in another would be impossible to reason about from the outside.
///
/// Pure and Foundation-only.
enum CoachBaseline {

    /// How many readings a personal baseline needs before it replaces the global one.
    ///
    /// Eight is roughly a fortnight of running for most people — enough that one bad day
    /// cannot define the baseline, few enough that the switch happens inside the first
    /// training block rather than at the end of it.
    static let sampleFloor = 8

    /// A resolved threshold, and where it came from.
    struct Resolved: Equatable, Sendable {
        /// The value a rule should compare against.
        let value: Double
        /// Whether `value` came from the runner's own readings.
        let isPersonal: Bool
        /// How many readings it was computed from. Zero when the global value is in use
        /// because there were none.
        let sampleCount: Int

        /// The derivation fragment for a card's working line — "your median of 172 spm
        /// over 14 runs", or nothing when the value is just the published figure.
        var derivationFragment: String? {
            guard isPersonal else { return nil }
            return String(
                localized: "your usual, from \(sampleCount) runs",
                comment: "Derivation fragment naming a personalised baseline"
            )
        }
    }

    /// Resolves a threshold from `samples`, falling back to `global` until there are
    /// enough of them.
    ///
    /// - Parameters:
    ///   - samples: the runner's readings. Order is irrelevant; the median is taken.
    ///   - global: the published figure to use until the switch.
    ///   - personalAdjustment: applied to the runner's median to turn a *typical* value
    ///     into a *threshold*. A rule fires on a departure from normal, not on normal
    ///     itself, so comparing against the bare median would fire half the time.
    static func resolve(
        samples: [Double],
        global: Double,
        personalAdjustment: (Double) -> Double
    ) -> Resolved {
        let usable = samples.filter { $0.isFinite && $0 > 0 }
        guard usable.count >= sampleFloor, let median = median(of: usable) else {
            return Resolved(value: global, isPersonal: false, sampleCount: usable.count)
        }
        return Resolved(
            value: personalAdjustment(median),
            isPersonal: true,
            sampleCount: usable.count
        )
    }

    /// The middle value, averaging the two middles on an even count.
    ///
    /// Median rather than mean throughout: one 22 km race effort in a month of easy runs
    /// drags a mean far enough to move a threshold, and the whole point of a personal
    /// baseline is to describe the runner's ordinary week.
    static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
