import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers `SmartCoachCards`, the dashboard's coaching strip.
///
/// Every rule in it is a threshold over the runner's own data, and it produces advice
/// about training and eating — so each one is pinned here on both sides of its threshold
/// rather than only where it fires. `now` is injected throughout so nothing depends on
/// the clock the suite happens to run on.
@MainActor
struct SmartCoachCardsTests {

    /// Fixed anchor: 2023-11-14 22:13:20 UTC, a Tuesday.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private func makeSession(
        in context: ModelContext,
        type: WorkoutType,
        daysFromNow: Int,
        distanceMeters: Double? = nil,
        paceBand: ClosedRange<Double>? = nil,
        location: WorkoutLocation = .outdoor
    ) -> ScheduledWorkout {
        let workout = ScheduledWorkout(
            scheduledDate: now.addingTimeInterval(Double(daysFromNow) * 86_400),
            workoutType: type,
            targetDistanceMeters: distanceMeters,
            targetPaceLowerBound: paceBand?.lowerBound,
            targetPaceUpperBound: paceBand?.upperBound
        )
        workout.workoutLocation = location
        context.insert(workout)
        return workout
    }

    private func makeRun(
        in context: ModelContext,
        daysAgo: Double,
        distanceMeters: Double,
        durationSeconds: Double,
        type: WorkoutType = .easy
    ) -> RunWorkout {
        let run = RunWorkout(
            date: now.addingTimeInterval(-daysAgo * 86_400),
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            workoutType: type
        )
        context.insert(run)
        return run
    }

    private func makeSplit(kilometer: Int, paceSecondsPerKm: Double) -> Split {
        Split(
            kilometer: kilometer,
            paceSecondsPerKm: paceSecondsPerKm,
            heartRate: nil,
            elevationGainMeters: 0,
            cumulativeDistanceMeters: Double(kilometer) * 1_000
        )
    }

    private func kinds(_ cards: [SmartCoachCard]) -> [SmartCoachCard.Kind] {
        cards.map(\.kind)
    }

    // MARK: - Shape of the result

    @Test("No plan and no runs produces no cards at all")
    func emptyStateProducesNothing() {
        let cards = SmartCoachCards.cards(
            nextSession: nil,
            recentRuns: [],
            profile: nil,
            unit: .metric,
            now: now
        )
        #expect(cards.isEmpty)
    }

    @Test("A quiet week still gets the preparation fallback rather than an empty strip")
    func fallbackFiresWhenNothingElseDoes() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .easy, daysFromNow: 2, distanceMeters: 6_000)

        let cards = SmartCoachCards.cards(
            nextSession: session,
            recentRuns: [],
            profile: nil,
            unit: .metric,
            now: now
        )
        #expect(kinds(cards) == [.prep])
    }

    @Test("The strip is capped at the requested number of cards")
    func resultIsCapped() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .longRun, daysFromNow: 1, distanceMeters: 22_000)
        // Enough history to trip the load card as well as the fuelling one.
        let runs = [
            makeRun(in: context, daysAgo: 1, distanceMeters: 20_000, durationSeconds: 7_200),
            makeRun(in: context, daysAgo: 3, distanceMeters: 20_000, durationSeconds: 7_200),
            makeRun(in: context, daysAgo: 9, distanceMeters: 12_000, durationSeconds: 4_320),
        ]

        let cards = SmartCoachCards.cards(
            nextSession: session,
            recentRuns: runs,
            profile: nil,
            unit: .metric,
            now: now,
            limit: 2
        )
        #expect(cards.count <= 2)
        // Identity is the kind, so the list never contains two of anything.
        #expect(Set(cards.map(\.id)).count == cards.count)
    }

    // MARK: - Race week

    @Test("A race inside the window produces a race-week card, and outside it does not")
    func raceWeekWindow() {
        let context = TestStore.makeContext()
        let profile = UserProfile(
            name: "Sam",
            goalRace: .marathon,
            goalFinishTime: 14_400,
            raceDate: now.addingTimeInterval(4 * 86_400),
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )
        context.insert(profile)

        let inside = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [], profile: profile, unit: .metric, now: now
        )
        #expect(kinds(inside).contains(.raceWeek))

        profile.raceDate = now.addingTimeInterval(Double(SmartCoachCards.raceWeekWindowDays + 3) * 86_400)
        let outside = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [], profile: profile, unit: .metric, now: now
        )
        #expect(!kinds(outside).contains(.raceWeek))
    }

    @Test("A past race date does not resurrect the race-week card")
    func raceInThePastDoesNotFire() {
        let context = TestStore.makeContext()
        let profile = UserProfile(
            name: "Sam",
            goalRace: .fiveK,
            goalFinishTime: 1_500,
            raceDate: now.addingTimeInterval(-2 * 86_400),
            weeklyRunDays: 3,
            fitnessLevel: .beginner
        )
        context.insert(profile)

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [], profile: profile, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.raceWeek))
    }

    @Test("Maintain-fitness profiles have no race to taper into")
    func maintainFitnessHasNoRaceWeek() {
        let context = TestStore.makeContext()
        let profile = UserProfile(
            name: "Sam",
            goalRace: .maintainFitness,
            goalFinishTime: 0,
            raceDate: now.addingTimeInterval(2 * 86_400),
            weeklyRunDays: 3,
            fitnessLevel: .beginner
        )
        context.insert(profile)

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [], profile: profile, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.raceWeek))
    }

    // MARK: - Refuel window

    @Test("A long run finished inside the window prompts a refuel")
    func refuelFiresInsideTheWindow() {
        let context = TestStore.makeContext()
        // Started 90 minutes ago, ran for 60 — finished half an hour back.
        let run = makeRun(
            in: context,
            daysAgo: 1.5 / 24,
            distanceMeters: 12_000,
            durationSeconds: 3_600,
            type: .longRun
        )

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.refuel))
    }

    @Test("The window is measured from the finish, not the start")
    func refuelWindowMeasuresFromTheFinish() {
        let context = TestStore.makeContext()
        // Started three hours ago — past the two-hour window — but ran for two of them,
        // so it finished an hour ago and is still worth refuelling.
        let run = makeRun(
            in: context,
            daysAgo: 3.0 / 24,
            distanceMeters: 24_000,
            durationSeconds: 2 * 3_600,
            type: .longRun
        )

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.refuel))
    }

    @Test("A short easy run does not earn a refuelling prompt")
    func refuelIgnoresShortEasyRuns() {
        let context = TestStore.makeContext()
        let run = makeRun(
            in: context,
            daysAgo: 0.5 / 24,
            distanceMeters: 4_000,
            durationSeconds: 1_200,
            type: .easy
        )

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.refuel))
    }

    @Test("Yesterday's run is outside the refuel window")
    func refuelExpires() {
        let context = TestStore.makeContext()
        let run = makeRun(
            in: context,
            daysAgo: 1,
            distanceMeters: 20_000,
            durationSeconds: 7_200,
            type: .longRun
        )

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.refuel))
    }

    // MARK: - Fuelling the next session

    @Test("A long run past the distance bar asks for fuel during it")
    func longRunAsksForInRunFuel() {
        let context = TestStore.makeContext()
        let session = makeSession(
            in: context,
            type: .longRun,
            daysFromNow: 2,
            distanceMeters: SmartCoachCards.inRunFuelDistanceMeters + 2_000
        )

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [], profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.longRunFuel))
    }

    @Test("A short long run falls through to no fuelling card at all")
    func shortLongRunDoesNotAskForFuel() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .longRun, daysFromNow: 2, distanceMeters: 10_000)

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [], profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.longRunFuel))
        #expect(!kinds(cards).contains(.sessionFuel))
    }

    @Test("An estimated duration past ninety minutes triggers in-run fuel without a long distance")
    func durationAloneTriggersInRunFuel() {
        let context = TestStore.makeContext()
        // 13 km at 7:30/km is 97 minutes — under the distance bar, over the time one.
        let session = makeSession(
            in: context,
            type: .longRun,
            daysFromNow: 3,
            distanceMeters: 13_000,
            paceBand: 450...450
        )

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [], profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.longRunFuel))
    }

    @Test("A tempo session asks to be eaten before, not during")
    func qualitySessionAsksForPreFuel() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .tempo, daysFromNow: 1, distanceMeters: 10_000)

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [], profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.sessionFuel))
        #expect(!kinds(cards).contains(.longRunFuel))
    }

    @Test("A strength day is not a run and gets no fuelling card")
    func strengthDayGetsNoFuellingCard() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .strength, daysFromNow: 1)

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [], profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.sessionFuel))
        #expect(!kinds(cards).contains(.longRunFuel))
        #expect(!kinds(cards).contains(.prep))
    }

    // MARK: - Heat

    @Test("Recent hot weather warns about hydration before an outdoor run")
    func heatFiresOnRecentHotWeather() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .easy, daysFromNow: 1, distanceMeters: 8_000)
        let run = makeRun(in: context, daysAgo: 2, distanceMeters: 8_000, durationSeconds: 2_400)
        run.weather = WorkoutWeather(
            temperatureCelsius: 28,
            feelsLikeCelsius: 31,
            humidityPercent: 62,
            windSpeedKmh: 8,
            conditionSymbol: "sun.max.fill",
            conditionDescription: "Clear"
        )

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.heat))
    }

    @Test("Humidity alone is enough, even in mild temperatures")
    func humidityAloneFires() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .easy, daysFromNow: 1, distanceMeters: 8_000)
        let run = makeRun(in: context, daysAgo: 1, distanceMeters: 8_000, durationSeconds: 2_400)
        run.weather = WorkoutWeather(
            temperatureCelsius: 16,
            feelsLikeCelsius: 16,
            humidityPercent: SmartCoachCards.heatHumidityPercent + 8,
            windSpeedKmh: 4,
            conditionSymbol: "cloud.fill",
            conditionDescription: "Humid"
        )

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.heat))
    }

    @Test("Cool, dry conditions say nothing about hydration")
    func mildWeatherDoesNotFire() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .easy, daysFromNow: 1, distanceMeters: 8_000)
        let run = makeRun(in: context, daysAgo: 1, distanceMeters: 8_000, durationSeconds: 2_400)
        run.weather = WorkoutWeather(
            temperatureCelsius: 9,
            feelsLikeCelsius: 7,
            humidityPercent: 55,
            windSpeedKmh: 12,
            conditionSymbol: "cloud.fill",
            conditionDescription: "Cloudy"
        )

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.heat))
    }

    @Test("An indoor next session ignores the weather outside")
    func indoorSessionIgnoresHeat() {
        let context = TestStore.makeContext()
        let session = makeSession(
            in: context,
            type: .easy,
            daysFromNow: 1,
            distanceMeters: 8_000,
            location: .indoor
        )
        let run = makeRun(in: context, daysAgo: 1, distanceMeters: 8_000, durationSeconds: 2_400)
        run.weather = WorkoutWeather(
            temperatureCelsius: 30,
            feelsLikeCelsius: 34,
            humidityPercent: 80,
            windSpeedKmh: 2,
            conditionSymbol: "sun.max.fill",
            conditionDescription: "Hot"
        )

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.heat))
    }

    @Test("A weather reading older than the lookback no longer describes conditions")
    func staleWeatherIsIgnored() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .easy, daysFromNow: 1, distanceMeters: 8_000)
        let run = makeRun(
            in: context,
            daysAgo: Double(SmartCoachCards.heatLookbackDays + 5),
            distanceMeters: 8_000,
            durationSeconds: 2_400
        )
        run.weather = WorkoutWeather(
            temperatureCelsius: 30,
            feelsLikeCelsius: 34,
            humidityPercent: 85,
            windSpeedKmh: 2,
            conditionSymbol: "sun.max.fill",
            conditionDescription: "Hot"
        )

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.heat))
    }

    // MARK: - Coming back

    @Test("A long gap since the last run asks for an easy way back")
    func comebackFiresAfterAGap() {
        let context = TestStore.makeContext()
        let run = makeRun(
            in: context,
            daysAgo: Double(SmartCoachCards.comebackDays + 2),
            distanceMeters: 6_000,
            durationSeconds: 2_100
        )

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.comeback))
    }

    @Test("A run two days ago is not a gap")
    func comebackDoesNotFireOnRecentRuns() {
        let context = TestStore.makeContext()
        let run = makeRun(in: context, daysAgo: 2, distanceMeters: 6_000, durationSeconds: 2_100)

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.comeback))
    }

    @Test("A runner who has never logged a run is not coming back from anything")
    func comebackNeedsHistory() {
        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [], profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.comeback))
    }

    // MARK: - Weekly load

    @Test("A sharp seven-day increase warns about the ramp")
    func loadFiresOnASharpRamp() {
        let context = TestStore.makeContext()
        let runs = [
            makeRun(in: context, daysAgo: 1, distanceMeters: 15_000, durationSeconds: 5_400),
            makeRun(in: context, daysAgo: 4, distanceMeters: 15_000, durationSeconds: 5_400),
            makeRun(in: context, daysAgo: 9, distanceMeters: 12_000, durationSeconds: 4_320),
        ]

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: runs, profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.load))
    }

    @Test("Holding volume steady says nothing")
    func loadIsQuietWhenVolumeHolds() {
        let context = TestStore.makeContext()
        let runs = [
            makeRun(in: context, daysAgo: 2, distanceMeters: 15_000, durationSeconds: 5_400),
            makeRun(in: context, daysAgo: 9, distanceMeters: 15_000, durationSeconds: 5_400),
        ]

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: runs, profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.load))
    }

    @Test("A near-zero base week does not make any increase a warning")
    func loadNeedsAMeaningfulBase() {
        let context = TestStore.makeContext()
        let runs = [
            makeRun(in: context, daysAgo: 2, distanceMeters: 8_000, durationSeconds: 2_880),
            makeRun(in: context, daysAgo: 9, distanceMeters: 2_000, durationSeconds: 720),
        ]

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: runs, profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.load))
    }

    // MARK: - Fading

    @Test("A run whose second half was slower asks for a slower start")
    func fadeFires() {
        let context = TestStore.makeContext()
        let run = makeRun(in: context, daysAgo: 1, distanceMeters: 6_000, durationSeconds: 1_920)
        run.splits = [
            makeSplit(kilometer: 1, paceSecondsPerKm: 300),
            makeSplit(kilometer: 2, paceSecondsPerKm: 300),
            makeSplit(kilometer: 3, paceSecondsPerKm: 340),
            makeSplit(kilometer: 4, paceSecondsPerKm: 350),
        ]

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.fade))
    }

    @Test("An evenly paced run is not a fade")
    func evenRunDoesNotFade() {
        let context = TestStore.makeContext()
        let run = makeRun(in: context, daysAgo: 1, distanceMeters: 6_000, durationSeconds: 1_800)
        run.splits = (1...6).map { makeSplit(kilometer: $0, paceSecondsPerKm: 300) }

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.fade))
    }

    @Test("Too few splits to compare halves says nothing")
    func fadeNeedsEnoughSplits() {
        let context = TestStore.makeContext()
        let run = makeRun(in: context, daysAgo: 1, distanceMeters: 3_000, durationSeconds: 1_050)
        run.splits = [
            makeSplit(kilometer: 1, paceSecondsPerKm: 300),
            makeSplit(kilometer: 2, paceSecondsPerKm: 400),
        ]

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.fade))
    }

    // MARK: - Easy versus hard

    @Test("Easy runs that sit on top of the hard ones ask to be slowed down")
    func polarizationFires() {
        let context = TestStore.makeContext()
        // 5:12/km easy against 5:00/km tempo — a 4% separation.
        let runs = [
            makeRun(in: context, daysAgo: 2, distanceMeters: 10_000, durationSeconds: 3_120, type: .easy),
            makeRun(in: context, daysAgo: 4, distanceMeters: 10_000, durationSeconds: 3_120, type: .easy),
            makeRun(in: context, daysAgo: 6, distanceMeters: 10_000, durationSeconds: 3_000, type: .tempo),
        ]

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: runs, profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.polarization))
    }

    @Test("A properly separated week says nothing")
    func polarizationQuietWhenSeparated() {
        let context = TestStore.makeContext()
        // 6:00/km easy against 4:30/km tempo — a 33% separation.
        let runs = [
            makeRun(in: context, daysAgo: 2, distanceMeters: 10_000, durationSeconds: 3_600, type: .easy),
            makeRun(in: context, daysAgo: 4, distanceMeters: 10_000, durationSeconds: 3_600, type: .easy),
            makeRun(in: context, daysAgo: 6, distanceMeters: 10_000, durationSeconds: 2_700, type: .tempo),
        ]

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: runs, profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.polarization))
    }

    @Test("With no quality run to compare against there is nothing to say")
    func polarizationNeedsBothSides() {
        let context = TestStore.makeContext()
        let runs = [
            makeRun(in: context, daysAgo: 2, distanceMeters: 10_000, durationSeconds: 3_120, type: .easy),
            makeRun(in: context, daysAgo: 4, distanceMeters: 10_000, durationSeconds: 3_120, type: .easy),
        ]

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: runs, profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.polarization))
    }

    // MARK: - Cadence

    @Test("Consistently low cadence suggests a turnover nudge")
    func cadenceFires() {
        let context = TestStore.makeContext()
        let runs = (1...3).map { index -> RunWorkout in
            let run = makeRun(
                in: context,
                daysAgo: Double(index) * 2,
                distanceMeters: 8_000,
                durationSeconds: 2_880
            )
            run.averageCadenceStepsPerMinute = 156
            return run
        }

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: runs, profile: nil, unit: .metric, now: now
        )
        #expect(kinds(cards).contains(.cadence))
    }

    @Test("Healthy cadence says nothing")
    func cadenceQuietWhenHealthy() {
        let context = TestStore.makeContext()
        let runs = (1...3).map { index -> RunWorkout in
            let run = makeRun(
                in: context,
                daysAgo: Double(index) * 2,
                distanceMeters: 8_000,
                durationSeconds: 2_880
            )
            run.averageCadenceStepsPerMinute = 178
            return run
        }

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: runs, profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.cadence))
    }

    @Test("Runs recorded without a pedometer reading are not counted as zero cadence")
    func cadenceIgnoresMissingReadings() {
        let context = TestStore.makeContext()
        let runs = (1...4).map { index in
            makeRun(in: context, daysAgo: Double(index) * 2, distanceMeters: 8_000, durationSeconds: 2_880)
        }

        let cards = SmartCoachCards.cards(
            nextSession: nil, recentRuns: runs, profile: nil, unit: .metric, now: now
        )
        #expect(!kinds(cards).contains(.cadence))
    }

    // MARK: - Ordering and categories

    @Test("Race week outranks everything else it competes with")
    func raceWeekLeads() {
        let context = TestStore.makeContext()
        let profile = UserProfile(
            name: "Sam",
            goalRace: .halfMarathon,
            goalFinishTime: 6_300,
            raceDate: now.addingTimeInterval(3 * 86_400),
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )
        context.insert(profile)
        let session = makeSession(in: context, type: .tempo, daysFromNow: 1, distanceMeters: 10_000)

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [], profile: profile, unit: .metric, now: now
        )
        #expect(cards.first?.kind == .raceWeek)
    }

    @Test("Fuelling cards are categorised as nutrition, form cards as training")
    func categoriesSplitCorrectly() {
        #expect(SmartCoachCard.Kind.longRunFuel.category == .nutrition)
        #expect(SmartCoachCard.Kind.refuel.category == .nutrition)
        #expect(SmartCoachCard.Kind.heat.category == .nutrition)
        #expect(SmartCoachCard.Kind.cadence.category == .training)
        #expect(SmartCoachCard.Kind.load.category == .training)
    }

    @Test("Every card produced carries text in both its title and its body")
    func cardsAreNeverBlank() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .longRun, daysFromNow: 1, distanceMeters: 20_000)
        let run = makeRun(in: context, daysAgo: 1, distanceMeters: 18_000, durationSeconds: 6_480, type: .longRun)

        let cards = SmartCoachCards.cards(
            nextSession: session, recentRuns: [run], profile: nil, unit: .metric, now: now
        )
        #expect(!cards.isEmpty)
        for card in cards {
            #expect(!card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!card.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("Card ordering does not depend on the order runs were handed in")
    func inputOrderDoesNotMatter() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .tempo, daysFromNow: 2, distanceMeters: 10_000)
        let runs = [
            makeRun(in: context, daysAgo: 1, distanceMeters: 15_000, durationSeconds: 5_400),
            makeRun(in: context, daysAgo: 4, distanceMeters: 15_000, durationSeconds: 5_400),
            makeRun(in: context, daysAgo: 9, distanceMeters: 12_000, durationSeconds: 4_320),
        ]

        let forwards = SmartCoachCards.cards(
            nextSession: session, recentRuns: runs, profile: nil, unit: .metric, now: now
        )
        let backwards = SmartCoachCards.cards(
            nextSession: session, recentRuns: Array(runs.reversed()), profile: nil, unit: .metric, now: now
        )
        #expect(forwards == backwards)
    }
}

// MARK: - Category helper

private extension SmartCoachCard.Kind {
    /// The category a card of this kind carries, reached without building the card.
    var category: SmartCoachCard.Category {
        SmartCoachCard(kind: self, title: "", message: "", tone: .neutral).category
    }
}
