import Foundation
import Testing
@testable import Stride

/// Covers `HeatAdaptationPolicy` — the pure half of the weather-tuning feature (N39).
///
/// Every number asserted here has a row in `docs/HEAT_ADAPTATION_EVIDENCE.md`. A failure
/// in this suite after a constant is edited is the point: the tests are what stop a
/// threshold moving without the doc moving with it.
@MainActor
struct HeatAdaptationPolicyTests {

    // MARK: Helpers

    private func conditions(
        temperature: Double,
        feelsLike: Double? = nil,
        humidity: Double,
        dewPoint: Double? = nil
    ) -> WorkoutWeather {
        WorkoutWeather(
            temperatureCelsius: temperature,
            feelsLikeCelsius: feelsLike ?? temperature,
            humidityPercent: humidity,
            dewPointCelsius: dewPoint,
            windSpeedKmh: 5,
            conditionSymbol: "sun.max.fill",
            conditionDescription: "Clear"
        )
    }

    // MARK: - Dew point

    @Test("Dew point matches the Magnus approximation")
    func dewPointFromHumidity() {
        // 30 °C at 50 % relative humidity is ~18.4 °C, the worked example in every
        // reference implementation of Magnus–Tetens.
        let dewPoint = HeatAdaptationPolicy.dewPointCelsius(
            temperatureCelsius: 30,
            relativeHumidityPercent: 50
        )
        #expect(abs(dewPoint - 18.4) < 0.2)
    }

    @Test("Saturated air puts the dew point at the air temperature")
    func dewPointAtSaturation() {
        let dewPoint = HeatAdaptationPolicy.dewPointCelsius(
            temperatureCelsius: 21,
            relativeHumidityPercent: 100
        )
        #expect(abs(dewPoint - 21) < 0.1)
    }

    @Test("Zero humidity is clamped rather than producing an infinite dew point")
    func dewPointSurvivesZeroHumidity() {
        // `log(0)` is `-inf`, and an infinite dew point propagates silently through every
        // comparison in the tier scales rather than failing where it happened.
        let dewPoint = HeatAdaptationPolicy.dewPointCelsius(
            temperatureCelsius: 20,
            relativeHumidityPercent: 0
        )
        #expect(dewPoint.isFinite)
        #expect(dewPoint < 0)
    }

    @Test("A forecast's own dew point is preferred over the derived one")
    func storedDewPointWins() {
        let weather = conditions(temperature: 30, humidity: 50, dewPoint: 11)
        #expect(HeatAdaptationPolicy.dewPointCelsius(for: weather) == 11)
    }

    // MARK: - Tiers

    @Test("A cool dry morning warrants nothing")
    func coolMorningIsNoTier() {
        let weather = conditions(temperature: 10, feelsLike: 9, humidity: 50)
        #expect(HeatAdaptationPolicy.tier(for: weather) == HeatStressTier.none)
    }

    @Test("Humidity escalates a merely warm day, via the dew point scale")
    func humidDayEscalates() {
        // 24 °C at 90 % is a ~22 °C dew point: the apparent-temperature scale calls this
        // `.moderate` on its own, and the dew point is what makes it worse than that.
        let humid = conditions(temperature: 24, feelsLike: 26, humidity: 90)
        let dry = conditions(temperature: 24, feelsLike: 26, humidity: 30)

        #expect(HeatAdaptationPolicy.tier(for: humid) == .high)
        #expect(HeatAdaptationPolicy.tier(for: dry) < HeatAdaptationPolicy.tier(for: humid))
    }

    @Test("Dry heat escalates through apparent temperature, which the humid scales miss")
    func dryHeatEscalates() {
        // 35 °C at 15 % has a dew point near 4 °C — invisible to both humidity-led scales,
        // and the reason the apparent-temperature read is consulted at all.
        let weather = conditions(temperature: 35, feelsLike: 36, humidity: 15)
        #expect(HeatAdaptationPolicy.tier(for: weather) == .severe)
    }

    @Test("The tier is the worst of the three scales, never an average of them")
    func tierTakesTheWorstScale() {
        // Mild air, saturated: only the dew-point scale has anything to say, and it wins.
        let weather = conditions(temperature: 22, feelsLike: 22, humidity: 100, dewPoint: 22)
        #expect(HeatAdaptationPolicy.tier(for: weather) == .high)
    }

    @Test("Tiers are ordered so thresholds read as comparisons")
    func tiersAreOrdered() {
        #expect(HeatStressTier.none < .mild)
        #expect(HeatStressTier.moderate < .severe)
        #expect(HeatStressTier.allCases == [.none, .mild, .moderate, .high, .severe, .extreme])
    }

    // MARK: - Pace adjustment

    @Test("Each tier's pace band matches the published table")
    func paceBandsMatchSources() {
        #expect(HeatAdaptationPolicy.paceAdjustmentPercent(for: .mild) == 0.5...2)
        #expect(HeatAdaptationPolicy.paceAdjustmentPercent(for: .moderate) == 2...4.5)
        #expect(HeatAdaptationPolicy.paceAdjustmentPercent(for: .high) == 4.5...8)
        #expect(HeatAdaptationPolicy.paceAdjustmentPercent(for: .severe) == 8...12)
        // Not "0 %" — the sources say to stop using pace as a target at all.
        #expect(HeatAdaptationPolicy.paceAdjustmentPercent(for: .extreme) == nil)
    }

    @Test("A pace bound moves slower, not faster")
    func paceBoundsSlowDown() {
        // Pace is seconds per kilometre, so slower is a larger number — the direction that
        // is easy to invert and impossible to notice from the tier alone.
        let adjusted = HeatAdaptationPolicy.adjustedPaceBound(300, for: .moderate)
        #expect(adjusted != nil)
        #expect((adjusted ?? 0) > 300)
        #expect(abs((adjusted ?? 0) - 309.75) < 0.01)
    }

    @Test("Extreme heat yields no adjusted bound at all")
    func extremeHasNoAdjustedBound() {
        #expect(HeatAdaptationPolicy.adjustedPaceBound(300, for: .extreme) == nil)
    }

    // MARK: - Prompting

    @Test("Quality and long sessions prompt a tier earlier than easy runs")
    func promptThresholdsDependOnSession() {
        #expect(HeatAdaptationPolicy.shouldPrompt(tier: .moderate, workoutType: .tempo))
        #expect(HeatAdaptationPolicy.shouldPrompt(tier: .moderate, workoutType: .interval))
        #expect(HeatAdaptationPolicy.shouldPrompt(tier: .moderate, workoutType: .longRun))

        // An easy run in moderate heat needs nothing beyond running to feel, which is what
        // an easy run already asks for. Prompting anyway is how notifications get muted.
        #expect(!HeatAdaptationPolicy.shouldPrompt(tier: .moderate, workoutType: .easy))
        #expect(HeatAdaptationPolicy.shouldPrompt(tier: .high, workoutType: .easy))
    }

    @Test("Nothing prompts below moderate")
    func mildNeverPrompts() {
        for type in WorkoutType.allCases {
            #expect(!HeatAdaptationPolicy.shouldPrompt(tier: .mild, workoutType: type))
            #expect(!HeatAdaptationPolicy.shouldPrompt(tier: HeatStressTier.none, workoutType: type))
        }
    }

    @Test("A race is never adapted, at any tier")
    func raceIsNeverPrompted() {
        // The race is the fixed point the block is built around — the same reason
        // `AdaptableWorkoutSelector` excludes it and `MissedWorkoutShift` won't move it.
        for tier in HeatStressTier.allCases {
            #expect(!HeatAdaptationPolicy.shouldPrompt(tier: tier, workoutType: .race))
        }
    }

    @Test("Sessions that are not runs are never prompted")
    func nonRunTypesAreNeverPrompted() {
        for type in [WorkoutType.rest, .strength, .crossTraining, .walk] {
            #expect(!HeatAdaptationPolicy.shouldPrompt(tier: .extreme, workoutType: type))
        }
    }

    @Test("An indoor or completed session is not advisable in the first place")
    func advisabilityFiltersTheObvious() {
        let now = Date()

        let indoor = ScheduledWorkout(scheduledDate: now.adding(days: 1), workoutType: .tempo)
        indoor.workoutLocation = .indoor
        #expect(!HeatAdaptationPolicy.isAdvisable(indoor, now: now))

        let done = ScheduledWorkout(scheduledDate: now.adding(days: 1), workoutType: .tempo)
        done.isCompleted = true
        #expect(!HeatAdaptationPolicy.isAdvisable(done, now: now))

        let past = ScheduledWorkout(scheduledDate: now.adding(days: -2), workoutType: .tempo)
        #expect(!HeatAdaptationPolicy.isAdvisable(past, now: now))

        let strength = ScheduledWorkout(scheduledDate: now.adding(days: 1), workoutType: .strength)
        #expect(!HeatAdaptationPolicy.isAdvisable(strength, now: now))

        let tempo = ScheduledWorkout(scheduledDate: now.adding(days: 1), workoutType: .tempo)
        #expect(HeatAdaptationPolicy.isAdvisable(tempo, now: now))
    }

    // MARK: - Adaptation

    @Test("A moderate day eases the pace band and leaves the session alone")
    func moderateEasesPaceOnly() {
        let workout = ScheduledWorkout(
            scheduledDate: Date().adding(days: 1),
            workoutType: .tempo,
            targetDistanceMeters: 8_000,
            targetPaceLowerBound: 260,
            targetPaceUpperBound: 275
        )

        let adaptation = HeatAdaptationPolicy.adaptation(for: workout, tier: .moderate, unit: .metric)

        #expect(adaptation.workoutType == .tempo)
        #expect(adaptation.workoutLocation == .outdoor)
        #expect(adaptation.targetDistanceMeters == 8_000)
        #expect((adaptation.targetPaceLowerBound ?? 0) > 260)
        #expect((adaptation.targetPaceUpperBound ?? 0) > 275)
        #expect(adaptation.changesAnything)
    }

    @Test("Severe heat converts a tempo to an easy run and drops its pace target")
    func severeConvertsQualityWork() {
        let workout = ScheduledWorkout(
            scheduledDate: Date().adding(days: 1),
            workoutType: .tempo,
            targetDistanceMeters: 8_000,
            targetPaceLowerBound: 260,
            targetPaceUpperBound: 275
        )

        let adaptation = HeatAdaptationPolicy.adaptation(for: workout, tier: .severe, unit: .metric)

        #expect(adaptation.workoutType == .easy)
        // An eased *tempo* band handed to a run that is now meant to be easy is still a
        // tempo band, and the runner would chase it.
        #expect(adaptation.targetPaceLowerBound == nil)
        #expect(adaptation.targetPaceUpperBound == nil)
        #expect(adaptation.clearsStructure)
        #expect(adaptation.workoutLocation == .indoor)
    }

    @Test("A long run is trimmed by distance rather than converted")
    func longRunLosesDistance() {
        let workout = ScheduledWorkout(
            scheduledDate: Date().adding(days: 1),
            workoutType: .longRun,
            targetDistanceMeters: 20_000,
            targetPaceLowerBound: 330,
            targetPaceUpperBound: 350
        )

        let adaptation = HeatAdaptationPolicy.adaptation(for: workout, tier: .severe, unit: .metric)

        #expect(adaptation.workoutType == .longRun)
        #expect(adaptation.targetDistanceMeters == 15_000)
        // Still a long run, so it keeps a (slower) band rather than losing its targets.
        #expect((adaptation.targetPaceLowerBound ?? 0) > 330)
    }

    @Test("Extreme heat strips pace targets from an easy run that has one")
    func extremeDropsTargets() {
        let workout = ScheduledWorkout(
            scheduledDate: Date().adding(days: 1),
            workoutType: .easy,
            targetDistanceMeters: 10_000,
            targetPaceLowerBound: 340,
            targetPaceUpperBound: 360
        )

        let adaptation = HeatAdaptationPolicy.adaptation(for: workout, tier: .extreme, unit: .metric)

        #expect(adaptation.targetPaceLowerBound == nil)
        #expect(adaptation.targetPaceUpperBound == nil)
        #expect(adaptation.workoutLocation == .indoor)
        #expect(adaptation.clearsStructure)
        // An easy run's distance is not what makes it costly in heat — its pace target is,
        // and that is what goes. Only long runs and quality volume are trimmed (§4).
        #expect(adaptation.targetDistanceMeters == 10_000)
    }

    @Test("A structured session's segment paces move with its band")
    func structureFollowsTheBand() {
        let workout = ScheduledWorkout(
            scheduledDate: Date().adding(days: 1),
            workoutType: .interval,
            targetPaceLowerBound: 240,
            targetPaceUpperBound: 250
        )
        workout.workoutStructure = WorkoutStructure(
            warmup: WorkoutSegment(distanceMeters: 1_600, targetPaceSecondsPerKm: 360, label: "Warm-up"),
            mainSets: [
                WorkoutSet(
                    repetitions: 5,
                    workSegment: WorkoutSegment(distanceMeters: 800, targetPaceSecondsPerKm: 240, label: "800 m"),
                    recoverySegment: WorkoutSegment(durationSeconds: 120, label: "Recovery jog"),
                    label: "800 m repeats"
                )
            ],
            cooldown: WorkoutSegment(distanceMeters: 1_600, targetPaceSecondsPerKm: 360, label: "Cool-down"),
            totalEstimatedDistanceMeters: 7_200,
            totalEstimatedDurationSeconds: 2_700
        )

        let adaptation = HeatAdaptationPolicy.adaptation(for: workout, tier: .high, unit: .metric)
        let structure = adaptation.workoutStructure

        #expect(structure != nil)
        // Leaving the structure's own paces alone would have the guided-run engine calling
        // out the pace the runner just agreed to back off from.
        #expect((structure?.mainSets.first?.workSegment.targetPaceSecondsPerKm ?? 0) > 240)
        // `.high` cuts quality volume to 80 %: five reps become four.
        #expect(structure?.mainSets.first?.repetitions == 4)
        #expect(!adaptation.clearsStructure)
    }

    @Test("A structured session never drops below a single repetition")
    func repetitionsHaveAFloor() {
        let structure = WorkoutStructure(
            warmup: WorkoutSegment(label: "Warm-up"),
            mainSets: [
                WorkoutSet(
                    repetitions: 1,
                    workSegment: WorkoutSegment(distanceMeters: 3_000, targetPaceSecondsPerKm: 250, label: "Tempo"),
                    recoverySegment: WorkoutSegment(label: "Recovery"),
                    label: "Tempo block"
                )
            ],
            cooldown: WorkoutSegment(label: "Cool-down"),
            totalEstimatedDistanceMeters: 6_000,
            totalEstimatedDurationSeconds: 2_100
        )

        let adapted = HeatAdaptationPolicy.adaptedStructure(
            structure,
            tier: .high,
            clears: false,
            volumeScale: 0.4
        )
        #expect(adapted?.mainSets.first?.repetitions == 1)
    }

    @Test("Applying an adaptation rewrites the prescription and nothing else")
    func applyTouchesOnlyThePrescription() {
        let scheduled = Date().adding(days: 1)
        let workout = ScheduledWorkout(
            scheduledDate: scheduled,
            workoutType: .tempo,
            targetDistanceMeters: 8_000,
            targetPaceLowerBound: 260,
            targetPaceUpperBound: 275
        )
        workout.healthKitPlanID = "watch-plan-id"
        let id = workout.id

        let adaptation = HeatAdaptationPolicy.adaptation(for: workout, tier: .severe, unit: .metric)
        HeatAdaptationPolicy.apply(adaptation, to: workout)

        #expect(workout.workoutType == .easy)
        #expect(workout.targetPaceLowerBound == nil)
        // The workout already on the Watch describes the old prescription, so it has to be
        // re-synced rather than matched.
        #expect(workout.healthKitPlanID == nil)
        // Identity, scheduling and completion are the coach's to leave alone.
        #expect(workout.id == id)
        #expect(workout.scheduledDate == scheduled)
        #expect(!workout.isCompleted)
    }

    @Test("An adaptation that would change nothing says so")
    func noOpAdaptationIsDetectable() {
        // An easy run with no distance and no band, in heat that clears its prompt
        // threshold: there is advice to give, but an "Apply" button would do nothing.
        let workout = ScheduledWorkout(scheduledDate: Date().adding(days: 1), workoutType: .easy)
        let adaptation = HeatAdaptationPolicy.adaptation(for: workout, tier: .high, unit: .metric)

        #expect(adaptation.changes.count == 1)
        #expect(adaptation.targetDistanceMeters == nil)
        // Advice, not an edit — so the sheet offers no "Apply" button to press.
        #expect(!adaptation.changesAnything)
    }

    // MARK: - Cooler hour

    @Test("A cooler hour is only worth suggesting when it changes the tier meaningfully")
    func coolerHourNeedsBothTests() {
        let hot = conditions(temperature: 31, feelsLike: 33, humidity: 55)
        let barelyCooler = conditions(temperature: 30.5, feelsLike: 32, humidity: 55)
        let genuinelyCooler = conditions(temperature: 19, feelsLike: 19, humidity: 60)

        #expect(!HeatAdaptationPolicy.isWorthMoving(from: hot, to: barelyCooler))
        #expect(HeatAdaptationPolicy.isWorthMoving(from: hot, to: genuinelyCooler))
        // Never backwards.
        #expect(!HeatAdaptationPolicy.isWorthMoving(from: genuinelyCooler, to: hot))
    }

    @Test("The cooler-hour window excludes the middle of the night")
    func coolerHourWindowIsBounded() {
        // The sleep costs more than the degrees save.
        #expect(!HeatAdaptationPolicy.coolerHourWindow.contains(3))
        #expect(!HeatAdaptationPolicy.coolerHourWindow.contains(23))
        #expect(HeatAdaptationPolicy.coolerHourWindow.contains(6))
        #expect(HeatAdaptationPolicy.coolerHourWindow.contains(20))
    }
}
