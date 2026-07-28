import Foundation

// MARK: - SmartCoachCard

/// One piece of coaching on the dashboard: what to eat before the next session, or what
/// to change about how the last few went.
///
/// Carries its own `score`, which is what decides where it lands. Cards used to be
/// emitted in a hand-written priority order, so the answer to "why am I seeing this" was
/// "because it was seventh in a list"; now every rule reports how far past its threshold
/// the runner actually is, and the highest number leads.
struct SmartCoachCard: Identifiable, Equatable, Sendable {

    /// What the card is about. Doubles as identity — at most one card of each kind is
    /// ever produced, so this is stable across rebuilds and SwiftUI can diff the list
    /// without cards animating past each other on every render.
    enum Kind: String, Sendable, CaseIterable {

        // Situation cards. Exactly one of these is a candidate at any moment, chosen by
        // `CoachSituation`, and it competes on score like everything else — except for
        // the three exclusive ones, which take the strip outright.

        /// Race morning.
        case raceDay
        /// A race inside the week: how to eat through the taper.
        case raceWeek
        /// Nothing logged for long enough that getting back out is the whole job.
        case comeback
        /// A demanding run finished inside the recovery window.
        case refuel
        /// The next session is long enough to need fuelling *during* it.
        case longRunFuel
        /// The next session is hard enough that what was eaten beforehand decides it.
        case sessionFuel
        /// A run is scheduled and nothing about it needs special handling.
        case prep
        /// The plan covers today and asks for nothing.
        case restDay
        /// The plan exists but has not begun.
        case planStartsSoon
        /// The plan is over.
        case planFinished
        /// No active plan at all.
        case noPlan

        // Signal cards. Every one of these is scored from the runner's own data and
        // competes for the two supporting slots — or for the top one, when something has
        // gone far enough wrong to outrank the situation.

        /// Conditions were hot or humid enough to change the plan.
        case heat
        /// The last run's second half was materially slower than its first.
        case fade
        /// Easy runs and hard runs are being run at nearly the same pace.
        case polarization
        /// Cadence is sitting below where this runner usually turns over.
        case cadence
        /// Seven-day volume jumped well past the usual guideline.
        case load
    }

    /// Which half of the coaching a card belongs to. Rendered as the card's overline so a
    /// fuelling tip and a form tip are distinguishable at a glance.
    enum Category: String, Sendable {
        case nutrition
        case training

        /// The overline as it is drawn. Lives here rather than in the dashboard's view
        /// because the widget snapshot ships it too, and the dashboard and the Home
        /// Screen calling the same card two different things is exactly the drift the
        /// snapshot's "finished strings" rule exists to prevent.
        var label: String {
            switch self {
            case .nutrition: return String(localized: "FUEL", comment: "Coach card category overline")
            case .training:  return String(localized: "TRAINING", comment: "Coach card category overline")
            }
        }
    }

    enum Tone: String, Sendable {
        case positive
        case neutral
        case caution
    }

    let kind: Kind
    let title: String
    /// The dashboard's copy: two to four sentences, written for a screen the runner is
    /// already looking at.
    let message: String
    /// The same advice in one short sentence, for the surfaces that cannot take the long
    /// form — a `systemSmall` widget, a Lock Screen accessory, a spoken Siri answer.
    ///
    /// **It must not depend on when it is read.** The dashboard renders `message` the
    /// instant it is computed, but a glance is written into ``WidgetSnapshot`` when the
    /// app happens to run and read whenever the runner looks at their Home Screen, so
    /// "about 30 minutes ago" would be a lie by lunchtime. Relevance is handled
    /// separately by ``expiresAt``; this is only about wording.
    ///
    /// There is a second reason, and it is the one that bites hardest. `WidgetSnapshot`
    /// is `Equatable` so `WidgetRefreshService` can skip a reload when nothing moved —
    /// WidgetKit budgets reloads per widget per day. A glance containing an elapsed time
    /// would differ on every single write, so every foreground would spend a reload and
    /// the one that matters, right after a run is saved, would be the one dropped.
    let glance: String
    let tone: Tone
    /// How much this matters right now, 0–1. Ordering is by this and nothing else.
    let score: Double
    /// The working behind any number in `message` — "0.9 g/kg/h · 72 kg · ~1.6 h · 105 g
    /// total". Shown under the primary card, because a computed figure with no visible
    /// basis reads as a guess. Nil for cards that assert no number.
    let derivation: String?
    /// When this card stops being worth showing, or `nil` when it does not go off.
    ///
    /// Where `glance` keeps the *wording* true, this keeps the *relevance* true: a refuel
    /// prompt is pointless three hours after the run, and a race-day card is wrong the
    /// morning after. Read at render time, the way `RaceCountdown.daysRemaining(asOf:)`
    /// is, because the app is not running to retract it.
    ///
    /// Anchored to the data — a run's finish, a race's date — and never to `now`. An
    /// expiry computed as "two hours from this write" would move on every write, which
    /// is the reload-budget trap again.
    let expiresAt: Date?

    init(
        kind: Kind,
        title: String,
        message: String,
        glance: String,
        tone: Tone,
        score: Double,
        derivation: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.glance = glance
        self.tone = tone
        // Clamped at the boundary rather than trusted: a rule that divides by a
        // near-zero baseline can produce something absurd, and a score outside 0–1
        // would silently own the top slot forever.
        self.score = score.clamped(to: 0...1)
        self.derivation = derivation
        self.expiresAt = expiresAt
    }

    /// Whether the card is still worth showing at `now`.
    func isValid(asOf now: Date) -> Bool {
        guard let expiresAt else { return true }
        return now < expiresAt
    }

    var id: String { kind.rawValue }

    var category: Category {
        switch kind {
        case .raceDay, .raceWeek, .refuel, .longRunFuel, .sessionFuel, .heat, .restDay:
            return .nutrition
        case .comeback, .prep, .planStartsSoon, .planFinished, .noPlan,
             .fade, .polarization, .cadence, .load:
            return .training
        }
    }
}

// MARK: - Scoring

extension SmartCoachCard {

    /// How far past a threshold a reading is, mapped onto 0–1.
    ///
    /// Zero below the threshold, `base` the moment it is crossed, 1 at `ceiling` and
    /// above. The base matters: a rule that scored ~0 the instant it fired could never
    /// reach the primary slot, so a freshly-crossed threshold would be invisible until it
    /// got much worse.
    ///
    /// - Parameters:
    ///   - value: the reading — a percentage over, a count of days, a drift.
    ///   - threshold: where the rule starts having something to say.
    ///   - ceiling: where it is as urgent as it will get. Beyond this the score is 1.
    ///   - base: the score at exactly `threshold`.
    static func urgency(
        _ value: Double,
        threshold: Double,
        saturatingAt ceiling: Double,
        base: Double = 0.2
    ) -> Double {
        guard value >= threshold else { return 0 }
        guard ceiling > threshold else { return 1 }
        let fraction = ((value - threshold) / (ceiling - threshold)).clamped(to: 0...1)
        return (base + (1 - base) * fraction).clamped(to: 0...1)
    }

    /// The same, for readings where *smaller* is worse — cadence, or the gap between easy
    /// and hard pace.
    static func inverseUrgency(
        _ value: Double,
        threshold: Double,
        saturatingAt floor: Double,
        base: Double = 0.2
    ) -> Double {
        guard value <= threshold else { return 0 }
        guard floor < threshold else { return 1 }
        let fraction = ((threshold - value) / (threshold - floor)).clamped(to: 0...1)
        return (base + (1 - base) * fraction).clamped(to: 0...1)
    }
}
