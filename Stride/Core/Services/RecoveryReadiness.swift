import Foundation

// MARK: - RecoveryReadings

/// What Apple Health says about how the runner has recovered: overnight heart-rate
/// variability, resting heart rate, and how long they slept (B7).
///
/// Raw material only. `HealthKitRepository` fills it in and ``RecoveryReadiness`` reads
/// it; nothing is persisted, because every value is re-readable from Health and a copy
/// in SwiftData would be one more thing for CloudKit to carry.
struct RecoveryReadings: Equatable, Sendable {

    /// One calendar day's mean of a quantity — several HRV samples a night from a Watch,
    /// usually one resting-HR sample a day.
    struct Day: Equatable, Sendable {
        /// Start of the day the samples fell on, in the calendar that grouped them.
        var day: Date
        var value: Double
    }

    /// Daily mean SDNN in milliseconds, oldest first.
    var heartRateVariability: [Day]
    /// Daily mean resting heart rate in beats per minute, oldest first.
    var restingHeartRate: [Day]
    /// Time actually asleep across last night, in seconds — `nil` when nothing was
    /// recorded, which is not the same as zero.
    var lastNightSleepSeconds: Double?

    init(
        heartRateVariability: [Day] = [],
        restingHeartRate: [Day] = [],
        lastNightSleepSeconds: Double? = nil
    ) {
        self.heartRateVariability = heartRateVariability
        self.restingHeartRate = restingHeartRate
        self.lastNightSleepSeconds = lastNightSleepSeconds
    }

    var isEmpty: Bool {
        heartRateVariability.isEmpty && restingHeartRate.isEmpty && lastNightSleepSeconds == nil
    }

    // MARK: Shaping raw samples

    /// Groups timestamped readings into per-day means, oldest first.
    ///
    /// Pure, so the grouping is testable without HealthKit. A Watch writes several SDNN
    /// readings a night, and a single one can be swung by when it happened to be taken;
    /// the day's mean is the number that means something against a baseline.
    static func dailyMeans(
        _ samples: [(date: Date, value: Double)],
        calendar: Calendar = .current
    ) -> [Day] {
        let grouped = Dictionary(grouping: samples.filter { $0.value > 0 }) {
            calendar.startOfDay(for: $0.date)
        }
        return grouped
            .map { day, readings in
                Day(day: day, value: readings.map(\.value).reduce(0, +) / Double(readings.count))
            }
            .sorted { $0.day < $1.day }
    }

    /// Total time covered by `intervals` inside `window`, counting overlaps once.
    ///
    /// Sleep arrives from every source that tracks it — a Watch, the iPhone's own bedtime
    /// estimate, a third-party ring — and they describe the same night. Summing them
    /// would credit a runner with fourteen hours; merging the intervals first gives the
    /// time during which *anything* says they were asleep.
    static func mergedDuration(
        of intervals: [DateInterval],
        within window: DateInterval
    ) -> TimeInterval {
        let clipped = intervals
            .compactMap { $0.intersection(with: window) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }

        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in clipped {
            guard let open = current else {
                current = interval
                continue
            }
            if interval.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, interval.end))
            } else {
                total += open.duration
                current = interval
            }
        }
        total += current?.duration ?? 0
        return total
    }

    /// The span "last night" covers for a morning read at `now`: from 18:00 the evening
    /// before today to `now`.
    ///
    /// Anchored to today's midnight rather than to `now` minus a fixed span, so a read at
    /// 07:00 and one at 13:00 look at the same night — the afternoon read would otherwise
    /// drop the start of it.
    static func lastNightWindow(endingAt now: Date, calendar: Calendar = .current) -> DateInterval {
        let midnight = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .hour, value: -6, to: midnight) ?? midnight
        return DateInterval(start: start, end: max(now, start))
    }
}

// MARK: - RecoveryReadiness

/// A 0–100 readiness score from last night's recovery measured against the runner's
/// own recent norm, plus how hard the last week has been relative to the last month (B7).
///
/// Four components, each mapped onto 0 (clearly under-recovered) … 1 (nothing to see):
///
/// | Component | Reading | No penalty | Fully penalised |
/// | --- | --- | --- | --- |
/// | HRV | latest day vs its 28-day mean | ≥ 5% under | ≥ 30% under |
/// | Resting HR | latest day vs its 28-day mean | ≤ 2 bpm up | ≥ 8 bpm up |
/// | Sleep | last night, asleep time | ≥ 7.5 h | ≤ 5 h |
/// | Load | 7-day run time vs 28-day weekly average | ≤ 1.2× | ≥ 1.6× |
///
/// The score is their weighted mean over whichever components have data, so a runner
/// without a Watch still gets a reading from sleep and load. At least one of the three
/// body signals is required: load on its own is already the dashboard's volume card, and
/// a "readiness" that knows nothing about the body would be that card again.
///
/// **Against the runner, not a population.** An SDNN of 35 ms is low for one person and
/// normal for another, so HRV and resting HR are only ever compared to the runner's own
/// preceding four weeks, and neither is scored until there are seven days of it. Sleep
/// and load have fixed thresholds because they are meaningful as absolutes: seven and a
/// half hours is a guideline, and an acute:chronic ratio is already relative.
///
/// Pure and deterministic, with an injectable `now` and calendar.
struct RecoveryReadiness: Equatable, Sendable {

    // MARK: Thresholds

    static let baselineDays = 28
    static let minimumBaselineDays = 7
    /// How stale the latest HRV / resting-HR day can be and still describe "now". One
    /// means yesterday's counts, which is what a morning read before the Watch has
    /// written today's resting HR will see.
    static let maximumReadingAgeDays = 1

    static let hrvDropFloorPercent = 5.0
    static let hrvDropCeilingPercent = 30.0
    static let restingRiseFloorBpm = 2.0
    static let restingRiseCeilingBpm = 8.0
    static let sleepGoodHours = 7.5
    static let sleepPoorHours = 5.0
    static let loadRatioFloor = 1.2
    static let loadRatioCeiling = 1.6
    /// Weekly running time the preceding month has to average before a ratio against it
    /// means anything — the same guard the volume card applies to its prior week.
    static let loadMinimumChronicMinutesPerWeek = 60.0

    static let weights: [Component.Kind: Double] = [
        .heartRateVariability: 0.35,
        .restingHeartRate: 0.25,
        .sleep: 0.25,
        .load: 0.15
    ]

    // MARK: Output

    struct Component: Equatable, Sendable {
        enum Kind: String, Sendable, CaseIterable {
            case heartRateVariability
            case restingHeartRate
            case sleep
            case load
        }

        let kind: Kind
        /// 0 is clearly under-recovered, 1 is nothing to see.
        let recovery: Double
        /// HRV: percent change against baseline (negative is a drop). Resting HR: bpm
        /// change against baseline. Sleep: hours. Load: the acute:chronic ratio.
        let reading: Double
        /// The day the reading describes — the HRV or resting-HR day, or the morning
        /// the sleep and load were read on.
        let asOf: Date
    }

    /// 0–100.
    let score: Int
    let components: [Component]
    /// The start of the day after the newest reading: when this stops describing "today".
    let validUntil: Date

    func component(_ kind: Component.Kind) -> Component? {
        components.first { $0.kind == kind }
    }

    /// The components pulling the score down, worst first.
    var drivers: [Component] {
        components
            .filter { $0.recovery < 0.7 }
            .sorted { $0.recovery < $1.recovery }
    }

    // MARK: Coach prompt

    /// The score and every component that fed it, as plain English for the AI coach's
    /// context. Not localized: it is model input, like the rest of the prompt.
    ///
    /// Carries the threshold with the number, so the model reads 55 as "ease off"
    /// rather than guessing what a readiness of 55 means on a scale it has never seen.
    var promptSummary: String {
        let parts = components.map { component -> String in
            switch component.kind {
            case .heartRateVariability:
                let percent = Int(component.reading.rounded())
                return percent < 0
                    ? "heart-rate variability \(abs(percent))% under their 4-week norm"
                    : "heart-rate variability \(percent)% above their 4-week norm"
            case .restingHeartRate:
                let bpm = Int(component.reading.rounded())
                return bpm < 0
                    ? "resting heart rate \(abs(bpm)) bpm below their 4-week norm"
                    : "resting heart rate \(bpm) bpm above their 4-week norm"
            case .sleep:
                return "slept \(String(format: "%.1f", component.reading)) hours last night"
            case .load:
                return "the last 7 days of running were \(String(format: "%.1f", component.reading))× their usual week"
            }
        }
        let verdict = Double(score) < SmartCoachCards.readinessThreshold
            ? "under 60, so today should be easy or a rest day"
            : "60 or above, so the plan can stand"
        return "Readiness this morning: \(score)/100 (\(verdict)). "
            + parts.joined(separator: "; ").capitalizedFirstCharacter + "."
    }

    // MARK: Evaluation

    /// Nil when there is no body signal to go on.
    static func evaluate(
        readings: RecoveryReadings,
        runs: [RunWorkout],
        now: Date,
        calendar: Calendar = .current
    ) -> RecoveryReadiness? {
        let today = calendar.startOfDay(for: now)
        var components: [Component] = []

        if let hrv = relativeToBaseline(readings.heartRateVariability, today: today, calendar: calendar) {
            let percent = (hrv.latest.value - hrv.baseline) / hrv.baseline * 100
            components.append(Component(
                kind: .heartRateVariability,
                recovery: 1 - penalty(-percent, from: hrvDropFloorPercent, to: hrvDropCeilingPercent),
                reading: percent,
                asOf: hrv.latest.day
            ))
        }

        if let resting = relativeToBaseline(readings.restingHeartRate, today: today, calendar: calendar) {
            let delta = resting.latest.value - resting.baseline
            components.append(Component(
                kind: .restingHeartRate,
                recovery: 1 - penalty(delta, from: restingRiseFloorBpm, to: restingRiseCeilingBpm),
                reading: delta,
                asOf: resting.latest.day
            ))
        }

        if let seconds = readings.lastNightSleepSeconds, seconds > 0 {
            let hours = seconds / 3_600
            components.append(Component(
                kind: .sleep,
                recovery: 1 - penalty(sleepGoodHours - hours, from: 0, to: sleepGoodHours - sleepPoorHours),
                reading: hours,
                asOf: today
            ))
        }

        // Load alone is not readiness — see the type's note.
        guard !components.isEmpty else { return nil }

        if let ratio = loadRatio(runs: runs, now: now) {
            components.append(Component(
                kind: .load,
                recovery: 1 - penalty(ratio, from: loadRatioFloor, to: loadRatioCeiling),
                reading: ratio,
                asOf: today
            ))
        }

        let totalWeight = components.reduce(0) { $0 + (weights[$1.kind] ?? 0) }
        let weighted = components.reduce(0) { $0 + (weights[$1.kind] ?? 0) * $1.recovery }
        let score = Int((weighted / totalWeight * 100).rounded())

        let newest = components.map(\.asOf).max() ?? today
        let validUntil = calendar.date(byAdding: .day, value: 1, to: newest) ?? newest

        return RecoveryReadiness(score: score, components: components, validUntil: validUntil)
    }

    /// Seven days of running time against the weekly average of the last twenty-eight.
    ///
    /// Time rather than distance so a hilly or trail week counts for what it cost, and
    /// the same windows are rolling rather than calendar weeks for the reason the volume
    /// card gives: a Tuesday comparison of a part-week always reads as a collapse.
    static func loadRatio(runs: [RunWorkout], now: Date) -> Double? {
        let day: TimeInterval = 86_400
        let acuteStart = now.addingTimeInterval(-7 * day)
        let chronicStart = now.addingTimeInterval(-Double(baselineDays) * day)

        let running = runs.runsOnly.filter { $0.date <= now }
        let acute = running.filter { $0.date > acuteStart }.reduce(0) { $0 + $1.durationSeconds }
        let chronic = running.filter { $0.date > chronicStart }.reduce(0) { $0 + $1.durationSeconds }
        let chronicWeekly = chronic / (Double(baselineDays) / 7)

        guard chronicWeekly / 60 >= loadMinimumChronicMinutesPerWeek else { return nil }
        return acute / chronicWeekly
    }

    // MARK: Helpers

    /// The newest day (if recent enough) and the mean of the days before it inside the
    /// baseline window, or nil when either is missing.
    private static func relativeToBaseline(
        _ days: [RecoveryReadings.Day],
        today: Date,
        calendar: Calendar
    ) -> (latest: RecoveryReadings.Day, baseline: Double)? {
        guard let latest = days.max(by: { $0.day < $1.day }),
              let age = calendar.dateComponents([.day], from: latest.day, to: today).day,
              age <= maximumReadingAgeDays,
              let baselineStart = calendar.date(byAdding: .day, value: -baselineDays, to: latest.day)
        else { return nil }

        let prior = days.filter { $0.day >= baselineStart && $0.day < latest.day }
        guard prior.count >= minimumBaselineDays else { return nil }
        let baseline = prior.map(\.value).reduce(0, +) / Double(prior.count)
        guard baseline > 0 else { return nil }
        return (latest, baseline)
    }

    /// 0 at or below `floor`, 1 at or above `ceiling`, linear between.
    private static func penalty(_ value: Double, from floor: Double, to ceiling: Double) -> Double {
        guard ceiling > floor else { return value >= ceiling ? 1 : 0 }
        return ((value - floor) / (ceiling - floor)).clamped(to: 0...1)
    }
}

private extension String {
    var capitalizedFirstCharacter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
