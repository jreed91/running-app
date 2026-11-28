import Foundation

// MARK: - HeatStressTier

/// How much the weather is going to cost the runner, on one ordered scale.
///
/// Ordered rather than a flat set because every decision downstream is a threshold —
/// "prompt from `.moderate`", "convert quality work from `.severe`" — and a `Comparable`
/// enum is what lets those read as the sentence they are.
public enum HeatStressTier: Int, Codable, Comparable, CaseIterable, Sendable {
    /// Nothing to say.
    case none = 0
    /// Noticeable, costs a little pace, needs no intervention.
    case mild = 1
    /// Pace targets stop being achievable at the prescribed effort.
    case moderate = 2
    /// Quality work is compromised and the session should be trimmed.
    case high = 3
    /// Hard running is not worth doing outside.
    case severe = 4
    /// Pace targets are abandoned; the session belongs indoors or on another day.
    case extreme = 5

    public static func < (lhs: HeatStressTier, rhs: HeatStressTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Short label for the advisory card and the notification.
    public var localizedName: String {
        switch self {
        case .none:     return String(localized: "Comfortable", comment: "Heat stress tier")
        case .mild:     return String(localized: "Warm", comment: "Heat stress tier")
        case .moderate: return String(localized: "Hot", comment: "Heat stress tier")
        case .high:     return String(localized: "Very hot", comment: "Heat stress tier")
        case .severe:   return String(localized: "Dangerous heat", comment: "Heat stress tier")
        case .extreme:  return String(localized: "Extreme heat", comment: "Heat stress tier")
        }
    }
}

// MARK: - HeatAdaptationPolicy

/// Everything Stride believes about running in heat, as constants with sources attached.
///
/// Every number here is justified in
/// [`docs/HEAT_ADAPTATION_EVIDENCE.md`](../../../docs/HEAT_ADAPTATION_EVIDENCE.md), and
/// the section each one comes from is named in its doc comment. **Read that file before
/// changing any of them, and update the row in the same change.** This is a health
/// feature: a prescription with no source behind it is exactly what this shape exists to
/// prevent, and it is the arrangement `PregnancyRunningPolicy` already uses for the same
/// reason.
///
/// Pure and stateless — no WeatherKit, no SwiftData, no clock beyond what is passed in —
/// so all of it is reachable from `HeatAdaptationPolicyTests`.
public enum HeatAdaptationPolicy {

    // MARK: - Dew point

    /// Magnus–Tetens coefficients (Sonntag 1990), accurate to about ±0.35 °C across
    /// −45…60 °C. Used only when the forecast carries no dew point of its own. §1.
    public static let magnusB = 17.62
    public static let magnusC = 243.12

    /// Dew point in Celsius, derived from air temperature and relative humidity.
    ///
    /// Humidity is clamped to a floor of 1 % rather than 0: `log(0)` is `-inf`, and a
    /// sensor or forecast reporting a flat zero would otherwise produce a dew point of
    /// `-inf` that propagates silently through every comparison below. §1.
    public static func dewPointCelsius(
        temperatureCelsius: Double,
        relativeHumidityPercent: Double
    ) -> Double {
        let humidity = min(max(relativeHumidityPercent, 1), 100) / 100
        let gamma = log(humidity) + (magnusB * temperatureCelsius) / (magnusC + temperatureCelsius)
        return (magnusC * gamma) / (magnusB - gamma)
    }

    /// The dew point for a set of conditions: the forecast's own reading when it has one,
    /// derived from temperature and humidity when it does not.
    public static func dewPointCelsius(for weather: WorkoutWeather) -> Double {
        weather.dewPointCelsius ?? dewPointCelsius(
            temperatureCelsius: weather.temperatureCelsius,
            relativeHumidityPercent: weather.humidityPercent
        )
    }

    // MARK: - Thresholds
    //
    // Each scale is a lower bound per tier, ordered from `.mild` upward: the tier is the
    // last bound the value clears. `.none` needs no entry — it is what falls through.

    /// Air temperature + dew point, both in Fahrenheit. The primary scale, and the only
    /// one published with a pace-adjustment band per bucket. §2a.
    public static let sumFahrenheitThresholds: [(tier: HeatStressTier, lowerBound: Double)] = [
        (.mild, 101),
        (.moderate, 131),
        (.high, 151),
        (.severe, 171),
        (.extreme, 181)
    ]

    /// Dew point alone, in Celsius — the evaporative ceiling, which the sum scale
    /// under-reads on a mild-but-saturated morning. §2b.
    public static let dewPointCelsiusThresholds: [(tier: HeatStressTier, lowerBound: Double)] = [
        (.mild, 12.8),
        (.moderate, 15.6),
        (.high, 18.3),
        (.severe, 23.9),
        (.extreme, 26.7)
    ]

    /// Apparent ("feels like") temperature in Celsius — the dry/radiant heat read that
    /// the two humidity-led scales under-read on a desert afternoon.
    ///
    /// Deliberately *not* WBGT: `apparentTemperature` carries no globe term, so the ACSM
    /// flag numbers are mapped conservatively rather than transplanted. The `.moderate`
    /// bound is the 22 °C that `SmartCoachCards.heatCard` already triggers on, so the
    /// retrospective card and this forecast agree about what counts as hot. §2c.
    public static let apparentCelsiusThresholds: [(tier: HeatStressTier, lowerBound: Double)] = [
        (.mild, 15),
        (.moderate, 22),
        (.high, 27),
        (.severe, 32),
        (.extreme, 37)
    ]

    // MARK: - Scoring

    /// The tier for a set of conditions: **the most severe of the three scales.**
    ///
    /// No single scale covers both a dry 38 °C afternoon and a saturated 24 °C dawn, and
    /// both change what a session should be — so whichever reads worst relative to its own
    /// thresholds wins. This is the same "max of two urgencies" shape
    /// `SmartCoachCards.heatCard` uses against recorded weather.
    public static func tier(for weather: WorkoutWeather) -> HeatStressTier {
        let dewPoint = dewPointCelsius(for: weather)
        let sumFahrenheit = celsiusToFahrenheit(weather.temperatureCelsius)
            + celsiusToFahrenheit(dewPoint)

        return max(
            tier(for: sumFahrenheit, on: sumFahrenheitThresholds),
            max(
                tier(for: dewPoint, on: dewPointCelsiusThresholds),
                tier(for: weather.feelsLikeCelsius, on: apparentCelsiusThresholds)
            )
        )
    }

    /// The last threshold `value` clears, or `.none` when it clears none of them.
    public static func tier(
        for value: Double,
        on thresholds: [(tier: HeatStressTier, lowerBound: Double)]
    ) -> HeatStressTier {
        thresholds.last { value >= $0.lowerBound }?.tier ?? .none
    }

    public static func celsiusToFahrenheit(_ celsius: Double) -> Double {
        celsius * 9 / 5 + 32
    }

    // MARK: - Pace adjustment

    /// How much slower the same effort runs, as a percentage band. `nil` above `.severe`,
    /// where the sources agree that pace targets should be abandoned entirely. §3.
    public static func paceAdjustmentPercent(for tier: HeatStressTier) -> ClosedRange<Double>? {
        switch tier {
        case .none:     return 0...0
        case .mild:     return 0.5...2
        case .moderate: return 2...4.5
        case .high:     return 4.5...8
        case .severe:   return 8...12
        case .extreme:  return nil
        }
    }

    /// The single figure actually applied to a session's pace bands — the midpoint of the
    /// published band. `nil` for `.extreme`, which drops targets rather than moving them.
    public static func representativePaceAdjustmentPercent(for tier: HeatStressTier) -> Double? {
        guard let band = paceAdjustmentPercent(for: tier) else { return nil }
        return (band.lowerBound + band.upperBound) / 2
    }

    /// A pace bound moved by the tier's adjustment.
    ///
    /// Pace is stored in **seconds per kilometre**, so slower is a larger number: a 5 %
    /// adjustment multiplies by 1.05 rather than dividing. Returns `nil` when the tier
    /// drops targets, which is the caller's signal to clear the bound rather than keep
    /// the old one.
    public static func adjustedPaceBound(_ bound: Double, for tier: HeatStressTier) -> Double? {
        guard let percent = representativePaceAdjustmentPercent(for: tier) else { return nil }
        return bound * (1 + percent / 100)
    }

    // MARK: - What changes about the session

    /// Whether the tier is severe enough that a tempo or interval session should be run
    /// as an easy run instead. §4.
    ///
    /// The stimulus is what is being protected, not the runner's willingness: a tempo held
    /// at the correct *effort* in this heat is a hard aerobic run with a tempo's recovery
    /// cost and none of its adaptation, and the session it was meant to set up is the one
    /// that pays for it.
    public static func convertsQualityToEasy(_ tier: HeatStressTier) -> Bool {
        tier >= .severe
    }

    /// Whether pace targets should be removed altogether rather than widened. §3.
    public static func dropsPaceTargets(_ tier: HeatStressTier) -> Bool {
        tier >= .extreme
    }

    /// Whether the session should be moved indoors — a treadmill, or a gym session. §4.
    public static func suggestsIndoor(_ tier: HeatStressTier) -> Bool {
        tier >= .severe
    }

    /// Fraction of the prescribed work volume a quality session keeps. §4.
    public static func qualityVolumeScale(for tier: HeatStressTier) -> Double {
        switch tier {
        case .none, .mild, .moderate: return 1.0
        case .high:                   return 0.8
        // Above `.high` a quality session is not shortened, it is converted — see
        // `convertsQualityToEasy`. The scale that then applies is the easy run's.
        case .severe, .extreme:       return 1.0
        }
    }

    /// Fraction of the prescribed distance a long run keeps. §4.
    ///
    /// Duration is what accumulates heat strain, so the session that spends longest out
    /// there is the one trimmed by distance — its intensity was already low.
    public static func longRunDistanceScale(for tier: HeatStressTier) -> Double {
        switch tier {
        case .none, .mild, .moderate: return 1.0
        case .high:                   return 0.9
        case .severe:                 return 0.75
        case .extreme:                return 0.7
        }
    }

    // MARK: - When to prompt

    /// Whether a session of this type, in these conditions, is worth waking the runner's
    /// phone the evening before. §5.
    ///
    /// Quality and long sessions have a pace target to miss and a recovery cost to pay, so
    /// they prompt a tier earlier than an easy run — which in moderate heat needs nothing
    /// beyond running to feel, which is what an easy run already asks for. Prompting anyway
    /// is how a runner learns to turn notifications off.
    public static func shouldPrompt(tier: HeatStressTier, workoutType: WorkoutType) -> Bool {
        switch workoutType {
        case .tempo, .interval, .longRun:
            return tier >= .moderate
        case .easy:
            return tier >= .high
        // A race is the fixed point the block is built around — the same reason
        // `AdaptableWorkoutSelector` excludes it and `MissedWorkoutShift` refuses to move
        // it. Rest, strength, cross-training and walks are not affected by the forecast in
        // any way this feature can act on.
        case .race, .rest, .crossTraining, .strength, .walk:
            return false
        }
    }

    // MARK: - The cooler hour

    /// The hours of the day a session may be moved into. §6.
    ///
    /// Bounded rather than open so the app never suggests a 03:00 start to dodge the heat:
    /// the sleep that costs is worth more than the degrees it saves.
    public static let coolerHourWindow: ClosedRange<Int> = 5...21

    /// How much cooler an alternative hour must be, in apparent temperature, before it is
    /// worth suggesting on top of dropping a tier. §6.
    public static let minimumCoolerHourGapCelsius = 2.0

    /// Whether moving from `planned` to `alternative` is worth telling the runner about.
    ///
    /// Both tests have to pass: a whole tier better *and* something they can feel. A
    /// suggestion to start an hour earlier for 1 °C is noise; one that turns a `.severe`
    /// tempo into a `.moderate` one is the entire intervention.
    public static func isWorthMoving(
        from planned: WorkoutWeather,
        to alternative: WorkoutWeather
    ) -> Bool {
        guard tier(for: alternative) < tier(for: planned) else { return false }
        return planned.feelsLikeCelsius - alternative.feelsLikeCelsius >= minimumCoolerHourGapCelsius
    }
}


// MARK: - Building the adaptation

extension HeatAdaptationPolicy {

    /// What this policy would do to a session, as data rather than as mutations.
    ///
    /// Separated from applying it because the sheet has to *show* the change before the
    /// runner accepts it, and a description assembled separately from the edit is a
    /// description that drifts from the edit. Both come from here.
    public struct Adaptation: Equatable, Sendable {
        /// The type the session becomes — unchanged unless quality work is being converted.
        public let workoutType: WorkoutType
        public let workoutLocation: WorkoutLocation
        public let targetDistanceMeters: Double?
        public let targetPaceLowerBound: Double?
        public let targetPaceUpperBound: Double?
        /// The structured form after adaptation, or `nil` when the session should no
        /// longer carry one. Left untouched — as the original — when the tier changes
        /// nothing about it.
        public let workoutStructure: WorkoutStructure?
        /// Whether the structured form and its intervals should be cleared outright.
        ///
        /// Distinct from `workoutStructure == nil`, which is also what a session that
        /// never had one looks like. Only this flag makes `apply` erase what is there.
        public let clearsStructure: Bool
        /// One line per change, in the order they are shown. May also carry a line of pure
        /// advice — "expect to run 6 % slower" — which is worth reading and changes nothing.
        public let changes: [String]

        /// Whether any *field* above actually moved.
        ///
        /// Deliberately not `!changes.isEmpty`. A tier can clear the prompt threshold and
        /// still change nothing the plan holds — an easy run with no band and no distance
        /// in `.high` heat earns a line of advice and no edit — and an "Apply" button that
        /// would silently do nothing is worse than the advice on its own.
        public let changesAnything: Bool

        public init(
            workoutType: WorkoutType,
            workoutLocation: WorkoutLocation,
            targetDistanceMeters: Double?,
            targetPaceLowerBound: Double?,
            targetPaceUpperBound: Double?,
            workoutStructure: WorkoutStructure?,
            clearsStructure: Bool,
            changes: [String],
            changesAnything: Bool
        ) {
            self.workoutType = workoutType
            self.workoutLocation = workoutLocation
            self.targetDistanceMeters = targetDistanceMeters
            self.targetPaceLowerBound = targetPaceLowerBound
            self.targetPaceUpperBound = targetPaceUpperBound
            self.workoutStructure = workoutStructure
            self.clearsStructure = clearsStructure
            self.changes = changes
            self.changesAnything = changesAnything
        }
    }

    /// The distance multiplier for a session, once the conversion decision is known.
    ///
    /// A converted session takes the long run's scale rather than the quality one: it is
    /// an easy run now, and what it costs is time on feet.
    public static func distanceScale(
        for workoutType: WorkoutType,
        tier: HeatStressTier,
        becameEasy: Bool
    ) -> Double {
        if becameEasy { return longRunDistanceScale(for: tier) }
        switch workoutType {
        case .longRun:          return longRunDistanceScale(for: tier)
        case .tempo, .interval: return qualityVolumeScale(for: tier)
        default:                return 1.0
        }
    }

    /// The structured form after adaptation.
    ///
    /// Structures carry their own per-segment paces, so a session whose top-level band was
    /// eased while its structure kept the original numbers would have the guided-run engine
    /// calling out the pace the runner just agreed to back off from. Every segment moves
    /// with the band, or the whole structure goes.
    ///
    /// The stored totals are **scaled rather than recomputed**: they are estimates that
    /// `TrainingPlanService` produced from the same segments, and recomputing them here
    /// with a second, subtly different summation is how the plan tab and the guided run
    /// would start disagreeing about how long a session is.
    public static func adaptedStructure(
        _ structure: WorkoutStructure?,
        tier: HeatStressTier,
        clears: Bool,
        volumeScale: Double
    ) -> WorkoutStructure? {
        guard let structure, !clears else { return nil }
        guard let percent = representativePaceAdjustmentPercent(for: tier) else { return nil }

        let paceFactor = 1 + percent / 100
        guard paceFactor > 1 || volumeScale < 1 else { return structure }

        var adapted = structure
        adapted.warmup = easedSegment(structure.warmup, paceFactor: paceFactor)
        adapted.cooldown = easedSegment(structure.cooldown, paceFactor: paceFactor)
        adapted.mainSets = structure.mainSets.map { set in
            var eased = set
            eased.workSegment = easedSegment(set.workSegment, paceFactor: paceFactor)
            eased.recoverySegment = easedSegment(set.recoverySegment, paceFactor: paceFactor)
            // Never below a single repetition: a set the runner is told to do zero times
            // is a set that should have been removed, and removing sets is a rewrite of
            // the session rather than an adjustment to it.
            eased.repetitions = max(1, Int((Double(set.repetitions) * volumeScale).rounded()))
            return eased
        }
        adapted.totalEstimatedDistanceMeters = structure.totalEstimatedDistanceMeters * volumeScale
        adapted.totalEstimatedDurationSeconds = structure.totalEstimatedDurationSeconds * volumeScale * paceFactor
        return adapted
    }

    private static func easedSegment(_ segment: WorkoutSegment, paceFactor: Double) -> WorkoutSegment {
        var eased = segment
        eased.targetPaceSecondsPerKm = segment.targetPaceSecondsPerKm.map { $0 * paceFactor }
        return eased
    }

    /// "4 × 800 m" style summary of what the sets became, for the change line.
    public static func repetitionText(_ sets: [WorkoutSet]) -> String {
        sets.map { "\($0.repetitions) × \($0.label)" }.joined(separator: ", ")
    }

    /// A percentage with one decimal, dropping a trailing `.0` — "3.3%", but "10%".
    public static func percentText(_ percent: Double) -> String {
        percent == percent.rounded()
            ? String(format: "%.0f", percent)
            : String(format: "%.1f", percent)
    }
}
