import Foundation

// MARK: - HeatStressTier

/// How much the weather is going to cost the runner, on one ordered scale.
///
/// Ordered rather than a flat set because every decision downstream is a threshold —
/// "prompt from `.moderate`", "convert quality work from `.severe`" — and a `Comparable`
/// enum is what lets those read as the sentence they are.
enum HeatStressTier: Int, Codable, Comparable, CaseIterable, Sendable {
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

    static func < (lhs: HeatStressTier, rhs: HeatStressTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Short label for the advisory card and the notification.
    var localizedName: String {
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
enum HeatAdaptationPolicy {

    // MARK: - Dew point

    /// Magnus–Tetens coefficients (Sonntag 1990), accurate to about ±0.35 °C across
    /// −45…60 °C. Used only when the forecast carries no dew point of its own. §1.
    static let magnusB = 17.62
    static let magnusC = 243.12

    /// Dew point in Celsius, derived from air temperature and relative humidity.
    ///
    /// Humidity is clamped to a floor of 1 % rather than 0: `log(0)` is `-inf`, and a
    /// sensor or forecast reporting a flat zero would otherwise produce a dew point of
    /// `-inf` that propagates silently through every comparison below. §1.
    static func dewPointCelsius(
        temperatureCelsius: Double,
        relativeHumidityPercent: Double
    ) -> Double {
        let humidity = min(max(relativeHumidityPercent, 1), 100) / 100
        let gamma = log(humidity) + (magnusB * temperatureCelsius) / (magnusC + temperatureCelsius)
        return (magnusC * gamma) / (magnusB - gamma)
    }

    /// The dew point for a set of conditions: the forecast's own reading when it has one,
    /// derived from temperature and humidity when it does not.
    static func dewPointCelsius(for weather: WorkoutWeather) -> Double {
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
    static let sumFahrenheitThresholds: [(tier: HeatStressTier, lowerBound: Double)] = [
        (.mild, 101),
        (.moderate, 131),
        (.high, 151),
        (.severe, 171),
        (.extreme, 181)
    ]

    /// Dew point alone, in Celsius — the evaporative ceiling, which the sum scale
    /// under-reads on a mild-but-saturated morning. §2b.
    static let dewPointCelsiusThresholds: [(tier: HeatStressTier, lowerBound: Double)] = [
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
    static let apparentCelsiusThresholds: [(tier: HeatStressTier, lowerBound: Double)] = [
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
    static func tier(for weather: WorkoutWeather) -> HeatStressTier {
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
    static func tier(
        for value: Double,
        on thresholds: [(tier: HeatStressTier, lowerBound: Double)]
    ) -> HeatStressTier {
        thresholds.last { value >= $0.lowerBound }?.tier ?? .none
    }

    static func celsiusToFahrenheit(_ celsius: Double) -> Double {
        celsius * 9 / 5 + 32
    }

    // MARK: - Pace adjustment

    /// How much slower the same effort runs, as a percentage band. `nil` above `.severe`,
    /// where the sources agree that pace targets should be abandoned entirely. §3.
    static func paceAdjustmentPercent(for tier: HeatStressTier) -> ClosedRange<Double>? {
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
    static func representativePaceAdjustmentPercent(for tier: HeatStressTier) -> Double? {
        guard let band = paceAdjustmentPercent(for: tier) else { return nil }
        return (band.lowerBound + band.upperBound) / 2
    }

    /// A pace bound moved by the tier's adjustment.
    ///
    /// Pace is stored in **seconds per kilometre**, so slower is a larger number: a 5 %
    /// adjustment multiplies by 1.05 rather than dividing. Returns `nil` when the tier
    /// drops targets, which is the caller's signal to clear the bound rather than keep
    /// the old one.
    static func adjustedPaceBound(_ bound: Double, for tier: HeatStressTier) -> Double? {
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
    static func convertsQualityToEasy(_ tier: HeatStressTier) -> Bool {
        tier >= .severe
    }

    /// Whether pace targets should be removed altogether rather than widened. §3.
    static func dropsPaceTargets(_ tier: HeatStressTier) -> Bool {
        tier >= .extreme
    }

    /// Whether the session should be moved indoors — a treadmill, or a gym session. §4.
    static func suggestsIndoor(_ tier: HeatStressTier) -> Bool {
        tier >= .severe
    }

    /// Fraction of the prescribed work volume a quality session keeps. §4.
    static func qualityVolumeScale(for tier: HeatStressTier) -> Double {
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
    static func longRunDistanceScale(for tier: HeatStressTier) -> Double {
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
    static func shouldPrompt(tier: HeatStressTier, workoutType: WorkoutType) -> Bool {
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

    /// Whether a scheduled session is eligible for a forecast advisory at all, before any
    /// weather is fetched. Cheap enough to run over a whole plan.
    static func isAdvisable(_ workout: ScheduledWorkout, now: Date = Date()) -> Bool {
        guard workout.workoutLocation == .outdoor else { return false }
        guard !workout.isCompleted else { return false }
        guard AdaptableWorkoutSelector.isAdaptableType(workout.workoutType) else { return false }
        return workout.scheduledDate >= now.startOfDay
    }

    // MARK: - The cooler hour

    /// The hours of the day a session may be moved into. §6.
    ///
    /// Bounded rather than open so the app never suggests a 03:00 start to dodge the heat:
    /// the sleep that costs is worth more than the degrees it saves.
    static let coolerHourWindow: ClosedRange<Int> = 5...21

    /// How much cooler an alternative hour must be, in apparent temperature, before it is
    /// worth suggesting on top of dropping a tier. §6.
    static let minimumCoolerHourGapCelsius = 2.0

    /// Whether moving from `planned` to `alternative` is worth telling the runner about.
    ///
    /// Both tests have to pass: a whole tier better *and* something they can feel. A
    /// suggestion to start an hour earlier for 1 °C is noise; one that turns a `.severe`
    /// tempo into a `.moderate` one is the entire intervention.
    static func isWorthMoving(
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
    struct Adaptation: Equatable, Sendable {
        /// The type the session becomes — unchanged unless quality work is being converted.
        let workoutType: WorkoutType
        let workoutLocation: WorkoutLocation
        let targetDistanceMeters: Double?
        let targetPaceLowerBound: Double?
        let targetPaceUpperBound: Double?
        /// The structured form after adaptation, or `nil` when the session should no
        /// longer carry one. Left untouched — as the original — when the tier changes
        /// nothing about it.
        let workoutStructure: WorkoutStructure?
        /// Whether the structured form and its intervals should be cleared outright.
        ///
        /// Distinct from `workoutStructure == nil`, which is also what a session that
        /// never had one looks like. Only this flag makes `apply` erase what is there.
        let clearsStructure: Bool
        /// One line per change, in the order they are shown. May also carry a line of pure
        /// advice — "expect to run 6 % slower" — which is worth reading and changes nothing.
        let changes: [String]

        /// Whether any *field* above actually moved.
        ///
        /// Deliberately not `!changes.isEmpty`. A tier can clear the prompt threshold and
        /// still change nothing the plan holds — an easy run with no band and no distance
        /// in `.high` heat earns a line of advice and no edit — and an "Apply" button that
        /// would silently do nothing is worse than the advice on its own.
        let changesAnything: Bool
    }

    /// The adaptation for one session in one set of conditions.
    ///
    /// Reads only the session's prescription and the tier, so the sheet, the tests, and
    /// the apply path all agree by construction.
    static func adaptation(
        for workout: ScheduledWorkout,
        tier: HeatStressTier,
        unit: UnitPreference
    ) -> Adaptation {
        var changes: [String] = []
        // Tracks whether a *field* moved, as opposed to a line of advice being added. See
        // `Adaptation.changesAnything`.
        var mutates = false

        let isQuality = workout.workoutType == .tempo || workout.workoutType == .interval
        let becomesEasy = isQuality && convertsQualityToEasy(tier)
        let newType: WorkoutType = becomesEasy ? .easy : workout.workoutType

        if becomesEasy {
            mutates = true
            changes.append(String(
                localized: "Your \(workout.workoutType.localizedName.lowercased()) becomes an easy run — the quality session isn't worth its recovery cost in this.",
                comment: "Heat adaptation change line: a hard session is converted to an easy run"
            ))
        }

        // MARK: Distance

        let volumeScale = distanceScale(for: workout.workoutType, tier: tier, becameEasy: becomesEasy)
        var distance = workout.targetDistanceMeters
        if let original = distance, volumeScale < 1 {
            let scaled = original * volumeScale
            distance = scaled
            mutates = true
            changes.append(String(
                localized: """
                    Distance trimmed from \(original.distanceString(unit: unit)) to \
                    \(scaled.distanceString(unit: unit)) — heat strain builds with time on your feet.
                    """,
                comment: "Heat adaptation change line: the session's distance is reduced"
            ))
        }

        // MARK: Pace
        //
        // Three outcomes, and the order matters. A converted session loses its targets
        // outright — an eased *tempo* band is still a tempo band, and handing one to a run
        // that is now meant to be easy would have the runner chasing the session they just
        // agreed not to do. Above `.severe` the targets go for the published reason. Below
        // it they are widened.

        var lower = workout.targetPaceLowerBound
        var upper = workout.targetPaceUpperBound
        let hadPaceTargets = lower != nil || upper != nil
        let losesPaceTargets = becomesEasy || dropsPaceTargets(tier)

        if losesPaceTargets {
            lower = nil
            upper = nil
            if hadPaceTargets {
                mutates = true
                changes.append(becomesEasy
                    ? String(
                        localized: "Its pace target goes with it — run this one at a conversational effort.",
                        comment: "Heat adaptation change line: pace targets removed because the session became easy"
                    )
                    : String(
                        localized: "Pace targets removed — run this one entirely on effort.",
                        comment: "Heat adaptation change line: pace targets are dropped in extreme heat"
                    )
                )
            }
        } else if let percent = representativePaceAdjustmentPercent(for: tier), percent > 0 {
            lower = lower.flatMap { adjustedPaceBound($0, for: tier) }
            upper = upper.flatMap { adjustedPaceBound($0, for: tier) }

            if hadPaceTargets,
               let original = workout.targetPaceLowerBound ?? workout.targetPaceUpperBound,
               let adjusted = lower ?? upper {
                // Pace is stored per kilometre whatever the runner reads in, so the
                // difference is converted before it is spoken about.
                mutates = true
                let perUnit = (adjusted - original) * (unit == .metric ? 1 : 1.609344)
                changes.append(String(
                    localized: """
                        Pace targets eased by about \(Int(perUnit.rounded())) seconds per \
                        \(unit.distanceLabel) — roughly \(percentText(percent))% slower for \
                        the same effort.
                        """,
                    comment: "Heat adaptation change line: pace bands are widened"
                ))
            } else if !hadPaceTargets {
                // Nothing to move, but the expectation still belongs on the card.
                changes.append(String(
                    localized: "Expect to run roughly \(percentText(percent))% slower than usual for the same effort.",
                    comment: "Heat adaptation change line: expected slowdown when the session has no pace band"
                ))
            }
        }

        // MARK: Structure

        let structure = adaptedStructure(
            workout.workoutStructure,
            tier: tier,
            clears: losesPaceTargets,
            volumeScale: volumeScale
        )
        // Compared on repetitions alone. Every segment's pace moves whenever the band
        // does, so comparing whole sets would fire this line on a `.moderate` session
        // whose rep count never changed.
        if let original = workout.workoutStructure, !losesPaceTargets, let structure,
           structure.mainSets.map(\.repetitions) != original.mainSets.map(\.repetitions) {
            mutates = true
            changes.append(String(
                localized: "The hard reps are cut back to \(repetitionText(structure.mainSets)) so the session still fits the day.",
                comment: "Heat adaptation change line: a structured session's repetitions are reduced"
            ))
        }

        // MARK: Location

        var location = workout.workoutLocation
        if suggestsIndoor(tier), location == .outdoor {
            location = .indoor
            mutates = true
            changes.append(String(
                localized: "Moved indoors — a treadmill is the safer place for this one.",
                comment: "Heat adaptation change line: the session is moved indoors"
            ))
        }

        return Adaptation(
            workoutType: newType,
            workoutLocation: location,
            targetDistanceMeters: distance,
            targetPaceLowerBound: lower,
            targetPaceUpperBound: upper,
            workoutStructure: structure,
            clearsStructure: losesPaceTargets,
            changes: changes,
            changesAnything: mutates
        )
    }

    /// The distance multiplier for a session, once the conversion decision is known.
    ///
    /// A converted session takes the long run's scale rather than the quality one: it is
    /// an easy run now, and what it costs is time on feet.
    static func distanceScale(
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
    static func adaptedStructure(
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
    private static func repetitionText(_ sets: [WorkoutSet]) -> String {
        sets.map { "\($0.repetitions) × \($0.label)" }.joined(separator: ", ")
    }

    /// A percentage with one decimal, dropping a trailing `.0` — "3.3%", but "10%".
    private static func percentText(_ percent: Double) -> String {
        percent == percent.rounded()
            ? String(format: "%.0f", percent)
            : String(format: "%.1f", percent)
    }

    /// Writes an adaptation onto the session it was computed for.
    ///
    /// Deliberately narrow: this touches the prescription and nothing else. Identity,
    /// scheduling, and completion state are left alone for the same reason
    /// `ScheduledWorkout.applyAdaptation(from:)` leaves them alone — heat changes what the
    /// session *is*, never when it is or whether it happened.
    ///
    /// `healthKitPlanID` is cleared because the workout already on the Watch describes the
    /// old prescription: it has to be re-synced rather than matched. Forgetting that is the
    /// failure `applyAdaptation(from:)`'s doc comment calls out, and it is just as easy to
    /// forget here.
    @MainActor
    static func apply(_ adaptation: Adaptation, to workout: ScheduledWorkout) {
        workout.workoutType = adaptation.workoutType
        workout.workoutLocation = adaptation.workoutLocation
        workout.targetDistanceMeters = adaptation.targetDistanceMeters
        workout.targetPaceLowerBound = adaptation.targetPaceLowerBound
        workout.targetPaceUpperBound = adaptation.targetPaceUpperBound

        if adaptation.clearsStructure {
            workout.workoutStructure = nil
            workout.intervalsData = nil
        } else if let structure = adaptation.workoutStructure {
            workout.workoutStructure = structure
        }

        workout.healthKitPlanID = nil
    }
}
