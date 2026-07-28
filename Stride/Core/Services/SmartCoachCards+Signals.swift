import Foundation

// MARK: - Signals

/// The scored rules: everything the runner's own data can say, independent of which
/// situation they are in.
///
/// Each one returns a card carrying a 0–1 urgency derived from how far past its threshold
/// the reading actually is, so a 45% volume jump and a 21% one are not the same card with
/// the same claim on the runner's attention. A rule that has nothing to say returns `nil`
/// rather than a zero-scored card, so "didn't fire" and "fired weakly" stay distinct.
extension SmartCoachCards {

    // MARK: Thresholds
    //
    // Each rule has two: where it starts having something to say, and where it is as bad
    // as it needs to get. The second is what turns a boolean into a score.

    /// Apparent temperature at which heat starts costing pace, and where it is punishing.
    static let heatFeelsLikeCelsius = 22.0
    static let heatFeelsLikeCeilingCelsius = 34.0
    /// Relative humidity that does the same on its own.
    static let heatHumidityPercent = 70.0
    static let heatHumidityCeilingPercent = 95.0

    /// Second-half slowdown, as a percentage, that counts as fading — and as a rout.
    static let fadePercent = 5.0
    static let fadeCeilingPercent = 20.0
    /// Splits needed before a first-half/second-half comparison means anything.
    static let fadeMinimumSplits = 4

    /// How far back the easy-versus-hard comparison looks.
    static let polarizationLookbackDays = 28
    /// How much slower easy runs should be than quality runs, as a percentage. The global
    /// figure, used until the runner has enough history for their own.
    static let polarizationSeparationPercent = 8.0

    /// Cadence below which a turnover nudge is worth suggesting, and how far back to look.
    static let cadenceFloorStepsPerMinute = 165.0
    static let cadenceLookbackDays = 90
    /// Cadence is nudged against the runner's *own* median once there is enough of it:
    /// a runner who has always turned over at 158 is not doing anything wrong at 158.
    /// The threshold is their median less this, so the card fires on a real drop.
    static let cadencePersonalDropStepsPerMinute = 6.0

    /// Seven-day volume increase, as a percentage, that counts as a jump — and as reckless.
    static let loadRampPercent = 20.0
    static let loadCeilingPercent = 60.0
    /// Volume the previous week has to reach before a ramp is meaningful rather than
    /// arithmetic on a near-zero base.
    static let loadMinimumPriorMeters = 10_000.0

    // MARK: - Entry point

    /// Every signal the context supports, unranked.
    ///
    /// Deliberately takes no `CoachSituation`: a signal describes the runner's data and
    /// nothing else, and the situation's only say over these is whether they are consulted
    /// at all — which `cards` decides by short-circuiting the exclusive states before it
    /// gets here. A signal that needs a session to be meaningful, like heat, reads
    /// `context.nextSession` directly rather than being told the state twice.
    static func signals(_ context: Context) -> [SmartCoachCard?] {
        [
            heatCard(context),
            loadCard(context),
            fadeCard(context),
            polarizationCard(context),
            cadenceCard(context)
        ]
    }

    // MARK: - Heat

    static func heatCard(_ context: Context) -> SmartCoachCard? {
        guard let next = context.nextSession,
              next.workoutType.isRunType,
              next.workoutLocation == .outdoor else { return nil }

        let cutoff = context.now.addingTimeInterval(-Double(heatLookbackDays) * 86_400)
        guard let weather = context.recentRuns
            .first(where: { $0.date >= cutoff && $0.weather != nil })?
            .weather else { return nil }

        // Whichever of the two is more extreme relative to its own threshold — a humid
        // 18° day and a dry 30° one are both worth saying something about.
        let heatScore = SmartCoachCard.urgency(
            weather.feelsLikeCelsius,
            threshold: heatFeelsLikeCelsius,
            saturatingAt: heatFeelsLikeCeilingCelsius
        )
        let humidityScore = SmartCoachCard.urgency(
            weather.humidityPercent,
            threshold: heatHumidityPercent,
            saturatingAt: heatHumidityCeilingPercent
        )
        let score = max(heatScore, humidityScore)
        guard score > 0 else { return nil }

        let duration = NextUpBriefing.estimatedDurationSeconds(for: next)
        let fluid = CoachNutrition.fluid(
            bodyMassKg: context.bodyMassKilograms,
            feelsLikeCelsius: weather.feelsLikeCelsius
        )
        let humidity = Int(weather.humidityPercent.rounded())

        return SmartCoachCard(
            kind: .heat,
            title: String(localized: "Drink ahead of the heat", comment: "Coach card title"),
            message: String(
                localized: """
                Your last run out there felt like \(weather.feelsLikeString(unit: context.unit)) \
                at \(humidity)% humidity. Plan on \(fluid.amount)\(durationClause(duration)), \
                add electrolytes if you'll be out over an hour, and let the pace sit 10–20 \
                seconds per \(unitWord(context.unit)) slower for the same effort.
                """,
                comment: "Coach card body for hot or humid conditions"
            ),
            glance: String(
                localized: "Plan on \(fluid.amount), and let the pace sit slower for the same effort.",
                comment: "Short coach tip for hot or humid conditions"
            ),
            tone: .caution,
            score: score,
            derivation: fluid.derivation
        )
    }

    /// " across roughly 1.5 hours out there" — appended to the fluid amount so an hourly
    /// rate has a session length attached to it. Silent when the plan sets neither a
    /// distance nor a pace to multiply out, rather than guessing at one.
    private static func durationClause(_ durationSeconds: Double?) -> String {
        guard let seconds = durationSeconds, seconds >= 1_800 else { return "" }
        let hours = seconds / 3_600
        return String(
            localized: " across roughly \(String(format: "%.1f", hours)) hours out there",
            comment: "Clause naming how long a session will take, inside the heat card"
        )
    }

    // MARK: - Weekly load

    /// A rolling seven-day window against the seven before it, rather than this calendar
    /// week against last: a Tuesday comparison of a part-week to a whole one always reads
    /// as a collapse in volume, which is the opposite of the warning this card is for.
    static func loadCard(_ context: Context) -> SmartCoachCard? {
        let week: TimeInterval = 7 * 86_400
        let recentStart = context.now.addingTimeInterval(-week)
        let priorStart = context.now.addingTimeInterval(-2 * week)

        let recent = context.recentRuns
            .filter { $0.date > recentStart && $0.date <= context.now }
            .reduce(0.0) { $0 + $1.distanceMeters }
        let prior = context.recentRuns
            .filter { $0.date > priorStart && $0.date <= recentStart }
            .reduce(0.0) { $0 + $1.distanceMeters }

        guard prior >= loadMinimumPriorMeters else { return nil }
        let change = (recent - prior) / prior * 100
        let score = SmartCoachCard.urgency(
            change,
            threshold: loadRampPercent,
            saturatingAt: loadCeilingPercent
        )
        guard score > 0 else { return nil }

        return SmartCoachCard(
            kind: .load,
            title: String(localized: "Big week — hold it there", comment: "Coach card title"),
            message: String(
                localized: """
                You've covered \(recent.distanceString(unit: context.unit)) in the last \
                seven days, \(Int(change.rounded()))% up on the seven before. Jumps much \
                past 10% are where niggles start — sit at this volume for a week before \
                adding more, and keep the easy days genuinely easy.
                """,
                comment: "Coach card body for a sharp increase in weekly volume"
            ),
            // Number-free on purpose: the percentage is computed over a rolling seven-day
            // window, so it drifts as runs age out of it even when nothing new is logged.
            // The advice does not drift, and it is the part that fits on a widget.
            glance: String(
                localized: "Volume is up sharply. Hold it here for a week before adding more.",
                comment: "Short coach tip for a sharp increase in weekly volume"
            ),
            tone: .caution,
            score: score,
            derivation: CoachNutrition.derivation([
                recent.distanceString(unit: context.unit),
                String(
                    localized: "vs \(prior.distanceString(unit: context.unit)) the week before",
                    comment: "Derivation fragment comparing two weeks of volume"
                ),
                "+\(Int(change.rounded()))%"
            ])
        )
    }

    // MARK: - Fading

    static func fadeCard(_ context: Context) -> SmartCoachCard? {
        guard let run = context.recentRuns.first(where: {
            context.now.timeIntervalSince($0.date) <= 7 * 86_400
        }) else { return nil }

        let splits = run.splits
            .filter { $0.paceSecondsPerKm > 0 }
            .sorted { $0.kilometer < $1.kilometer }
        guard splits.count >= fadeMinimumSplits else { return nil }

        // An odd split count drops its middle rather than counting it on both sides.
        let half = splits.count / 2
        let opening = average(splits.prefix(half).map(\.paceSecondsPerKm))
        let closing = average(splits.suffix(half).map(\.paceSecondsPerKm))
        guard opening > 0 else { return nil }

        let drift = (closing - opening) / opening * 100
        let score = SmartCoachCard.urgency(
            drift,
            threshold: fadePercent,
            saturatingAt: fadeCeilingPercent
        )
        guard score > 0 else { return nil }

        return SmartCoachCard(
            kind: .fade,
            title: String(localized: "Start the next one slower", comment: "Coach card title"),
            message: String(
                localized: """
                You gave back \(Int(drift.rounded()))% over the back half of your last run — \
                \(opening.paceString(unit: context.unit)) early against \
                \(closing.paceString(unit: context.unit)) late. Open 10–15 seconds per \
                \(unitWord(context.unit)) slower than feels right; the back half usually \
                hands it all back and then some.
                """,
                comment: "Coach card body for a run whose second half was slower"
            ),
            glance: String(
                localized: "Open the next one 10–15 seconds per \(unitWord(context.unit)) slower.",
                comment: "Short coach tip for a run whose second half was slower"
            ),
            tone: .caution,
            score: score,
            derivation: CoachNutrition.derivation([
                String(
                    localized: "\(splits.count) splits",
                    comment: "Derivation fragment naming how many splits a fade was measured over"
                ),
                "\(opening.paceValueString(unit: context.unit)) → \(closing.paceValueString(unit: context.unit))"
            ])
        )
    }

    // MARK: - Easy days versus hard days

    static func polarizationCard(_ context: Context) -> SmartCoachCard? {
        let cutoff = context.now.addingTimeInterval(-Double(polarizationLookbackDays) * 86_400)
        let window = context.recentRuns.filter { $0.date >= cutoff && $0.averagePaceSecondsPerKm > 0 }

        let easy = window.filter { $0.workoutType == .easy }.map(\.averagePaceSecondsPerKm)
        let quality = window.filter { $0.workoutType.isQualitySession }.map(\.averagePaceSecondsPerKm)
        guard easy.count >= 2, !quality.isEmpty else { return nil }

        let easyPace = average(easy)
        let qualityPace = average(quality)
        guard qualityPace > 0 else { return nil }

        // Pace is seconds per unit distance, so slower is a *larger* number.
        let separation = (easyPace - qualityPace) / qualityPace * 100
        // Smaller separation is worse, so this is the inverse form. Saturates at zero:
        // easy runs no slower than hard ones is as collapsed as the distinction gets.
        let score = SmartCoachCard.inverseUrgency(
            separation,
            threshold: polarizationSeparationPercent,
            saturatingAt: 0
        )
        guard score > 0 else { return nil }

        let comparison = separation <= 0
            ? String(
                localized: "as quick as your hard ones (\(qualityPace.paceString(unit: context.unit)))",
                comment: "Coach card clause when easy runs are no slower than quality runs"
            )
            : String(
                localized: """
                only \(Int(separation.rounded()))% slower than your hard ones \
                (\(qualityPace.paceString(unit: context.unit)))
                """,
                comment: "Coach card clause comparing easy-run pace to quality-run pace"
            )

        return SmartCoachCard(
            kind: .polarization,
            title: String(localized: "Let the easy days be easy", comment: "Coach card title"),
            message: String(
                localized: """
                Your easy runs are averaging \(easyPace.paceString(unit: context.unit)) — \
                \(comparison). Easy days that creep quick leave less for the sessions that \
                actually build speed. Try holding them 30–45 seconds per \
                \(unitWord(context.unit)) further back.
                """,
                comment: "Coach card body when easy and hard runs are run at similar paces"
            ),
            glance: String(
                localized: "Hold the easy days 30–45 seconds per \(unitWord(context.unit)) further back.",
                comment: "Short coach tip when easy and hard runs are run at similar paces"
            ),
            tone: .neutral,
            score: score,
            derivation: CoachNutrition.derivation([
                String(
                    localized: "\(easy.count) easy vs \(quality.count) hard runs",
                    comment: "Derivation fragment naming the sample behind the easy/hard comparison"
                ),
                "\(Int(separation.rounded()))% apart"
            ])
        )
    }

    // MARK: - Cadence

    /// Judged against the runner's own median once there are enough readings for one.
    ///
    /// This is the rule the global constant served worst. 165 steps a minute is a
    /// population figure; measured against it, a runner who has turned over at 158 for
    /// years is told to fix something that is simply how they run, while one who has
    /// dropped from 182 to 170 — a real change, and usually a tired or sore one — is told
    /// nothing at all.
    static func cadenceCard(_ context: Context) -> SmartCoachCard? {
        let cutoff = context.now.addingTimeInterval(-Double(cadenceLookbackDays) * 86_400)
        let history = context.recentRuns
            .filter { $0.date >= cutoff }
            .compactMap { $0.averageCadenceStepsPerMinute }
            .filter { $0 > 0 }
        guard !history.isEmpty else { return nil }

        let baseline = CoachBaseline.resolve(
            samples: history,
            global: cadenceFloorStepsPerMinute,
            personalAdjustment: { $0 - cadencePersonalDropStepsPerMinute }
        )

        // Recent form against that baseline: the last three readings, so one flat run
        // does not fire the card and a fortnight of them does.
        let recent = Array(history.prefix(3))
        guard recent.count >= 3 else { return nil }
        let mean = average(recent)

        let score = SmartCoachCard.inverseUrgency(
            mean,
            threshold: baseline.value,
            saturatingAt: baseline.value - 15
        )
        guard score > 0 else { return nil }

        let target = Int((mean * 1.05).rounded())
        return SmartCoachCard(
            kind: .cadence,
            title: String(localized: "Nudge your turnover up", comment: "Coach card title"),
            message: String(
                localized: """
                Your last \(recent.count) runs averaged \(Int(mean.rounded())) steps a \
                minute\(baselineClause(baseline)). Lifting that about 5% — roughly \
                \(target) — shortens the stride and puts each foot down under you rather \
                than out in front. Try it on the easy days first.
                """,
                comment: "Coach card body for low running cadence"
            ),
            glance: String(
                localized: "Nudge your turnover about 5% higher, starting on the easy days.",
                comment: "Short coach tip for low running cadence"
            ),
            tone: .neutral,
            score: score,
            derivation: CoachNutrition.derivation([
                String(
                    localized: "\(Int(baseline.value.rounded())) spm threshold",
                    comment: "Derivation fragment naming the cadence threshold"
                ),
                baseline.derivationFragment ?? String(
                    localized: "published guideline",
                    comment: "Derivation fragment for a threshold that is not yet personalised"
                )
            ])
        )
    }

    /// ", against your usual 176" — only once the baseline is the runner's own. Before
    /// that there is nothing honest to compare to.
    private static func baselineClause(_ baseline: CoachBaseline.Resolved) -> String {
        guard baseline.isPersonal else { return "" }
        let usual = Int((baseline.value + cadencePersonalDropStepsPerMinute).rounded())
        return String(
            localized: ", against your usual \(usual)",
            comment: "Clause comparing recent cadence to the runner's own median"
        )
    }

    // MARK: - Helpers

    static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// The distance unit as it is spoken in a sentence — "per km", "per mile" — rather
    /// than as the abbreviation a metric cell uses.
    static func unitWord(_ unit: UnitPreference) -> String {
        switch unit {
        case .metric:   return String(localized: "km", comment: "Distance unit inside coach copy")
        case .imperial: return String(localized: "mile", comment: "Distance unit inside coach copy")
        }
    }
}
