import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers `SmartCoachCards` — the selection, not the copy.
///
/// The three steps it runs are the three things worth pinning: every state produces a
/// card, the exclusive states take the strip outright, and everything else is ordered by
/// score rather than by the order the rules happen to be written in.
@MainActor
struct SmartCoachCardsTests {

    /// Fixed anchor: 2023-11-14 22:13:20 UTC, a Tuesday.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Fixtures

    private func makeSession(
        in context: ModelContext,
        type: WorkoutType,
        daysFromNow: Int = 1,
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
        distanceMeters: Double = 10_000,
        durationSeconds: Double = 3_600,
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

    private func makeContext(
        nextSession: ScheduledWorkout? = nil,
        runs: [RunWorkout] = [],
        profile: UserProfile? = nil,
        dayState: ScheduledDayResolver.DayState = .noPlan,
        unit: UnitPreference = .metric
    ) -> SmartCoachCards.Context {
        SmartCoachCards.Context(
            nextSession: nextSession,
            recentRuns: runs,
            profile: profile,
            dayState: dayState,
            unit: unit,
            now: now
        )
    }

    private func kinds(_ cards: [SmartCoachCard]) -> [SmartCoachCard.Kind] {
        cards.map(\.kind)
    }

    // MARK: - Every state produces a card

    @Test("Each empty state gets its own card rather than a shared fallback")
    func everyEmptyStateHasItsOwnCard() {
        let expected: [(ScheduledDayResolver.DayState, SmartCoachCard.Kind)] = [
            (.rest, .restDay),
            (.beforePlanStart(daysUntilStart: 3), .planStartsSoon),
            (.outsidePlan, .planFinished),
            (.noPlan, .noPlan)
        ]
        for (dayState, kind) in expected {
            let cards = SmartCoachCards.cards(makeContext(dayState: dayState))
            #expect(cards.first?.kind == kind)
        }
    }

    @Test("A session ahead produces the card its shape calls for")
    func sessionShapesMapToCards() {
        let context = TestStore.makeContext()
        let long = makeSession(in: context, type: .longRun, distanceMeters: 22_000)
        let tempo = makeSession(in: context, type: .tempo, distanceMeters: 10_000)
        let easy = makeSession(in: context, type: .easy, distanceMeters: 6_000)
        let gym = makeSession(in: context, type: .strength)

        #expect(SmartCoachCards.cards(makeContext(nextSession: long)).first?.kind == .longRunFuel)
        #expect(SmartCoachCards.cards(makeContext(nextSession: tempo)).first?.kind == .sessionFuel)
        #expect(SmartCoachCards.cards(makeContext(nextSession: easy)).first?.kind == .prep)
        #expect(SmartCoachCards.cards(makeContext(nextSession: gym)).first?.kind == .prep)
    }

    @Test("Every card produced carries text in both its title and its body")
    func cardsAreNeverBlank() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .longRun, distanceMeters: 22_000)
        let runs = [
            makeRun(in: context, daysAgo: 1, distanceMeters: 18_000),
            makeRun(in: context, daysAgo: 4, distanceMeters: 16_000),
            makeRun(in: context, daysAgo: 9, distanceMeters: 12_000)
        ]

        let cards = SmartCoachCards.cards(makeContext(nextSession: session, runs: runs))
        #expect(!cards.isEmpty)
        for card in cards {
            #expect(!card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!card.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Exclusivity

    @Test("Race day takes the whole strip, however much else is wrong")
    func raceDayTakesTheStrip() {
        let context = TestStore.makeContext()
        let profile = UserProfile(
            name: "Sam",
            goalRace: .marathon,
            goalFinishTime: 14_400,
            raceDate: now,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )
        context.insert(profile)
        let session = makeSession(in: context, type: .longRun, distanceMeters: 30_000)
        // A load ramp steep enough to score 1.0 on its own.
        let runs = [
            makeRun(in: context, daysAgo: 1, distanceMeters: 40_000),
            makeRun(in: context, daysAgo: 9, distanceMeters: 12_000)
        ]

        let cards = SmartCoachCards.cards(makeContext(nextSession: session, runs: runs, profile: profile))
        #expect(kinds(cards) == [.raceDay])
    }

    @Test("A lay-off takes the whole strip too")
    func layoffTakesTheStrip() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .tempo, distanceMeters: 10_000)
        let run = makeRun(in: context, daysAgo: 21)

        let cards = SmartCoachCards.cards(makeContext(nextSession: session, runs: [run]))
        #expect(kinds(cards) == [.comeback])
    }

    @Test("An ordinary state does not take the strip")
    func ordinaryStateSharesTheStrip() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .easy, distanceMeters: 6_000)
        let runs = [
            makeRun(in: context, daysAgo: 1, distanceMeters: 20_000),
            makeRun(in: context, daysAgo: 3, distanceMeters: 20_000),
            makeRun(in: context, daysAgo: 9, distanceMeters: 12_000)
        ]

        let cards = SmartCoachCards.cards(makeContext(nextSession: session, runs: runs))
        #expect(cards.count > 1)
    }

    // MARK: - Scoring and ordering

    @Test("Cards come back in descending score order")
    func cardsAreRankedByScore() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .easy, distanceMeters: 6_000)
        let runs = [
            makeRun(in: context, daysAgo: 1, distanceMeters: 25_000),
            makeRun(in: context, daysAgo: 4, distanceMeters: 25_000),
            makeRun(in: context, daysAgo: 9, distanceMeters: 15_000)
        ]

        let cards = SmartCoachCards.cards(makeContext(nextSession: session, runs: runs))
        let scores = cards.map(\.score)
        #expect(scores == scores.sorted(by: >))
    }

    @Test("A severe volume jump outranks a routine preparation note")
    func severeSignalBeatsTheSituationCard() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .easy, distanceMeters: 6_000)
        // 12 km one week, 48 km the next — a 300% ramp.
        let runs = [
            makeRun(in: context, daysAgo: 1, distanceMeters: 24_000),
            makeRun(in: context, daysAgo: 3, distanceMeters: 24_000),
            makeRun(in: context, daysAgo: 9, distanceMeters: 12_000)
        ]

        let cards = SmartCoachCards.cards(makeContext(nextSession: session, runs: runs))
        #expect(cards.first?.kind == .load)
    }

    @Test("A mild volume jump does not outrank fuelling a long run")
    func mildSignalLosesToTheSituationCard() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .longRun, distanceMeters: 22_000)
        // 20 km against 16 km — a 25% ramp, barely over the threshold.
        let runs = [
            makeRun(in: context, daysAgo: 2, distanceMeters: 20_000),
            makeRun(in: context, daysAgo: 9, distanceMeters: 16_000)
        ]

        let cards = SmartCoachCards.cards(makeContext(nextSession: session, runs: runs))
        #expect(cards.first?.kind == .longRunFuel)
        #expect(kinds(cards).contains(.load))
    }

    @Test("The recovery card decays across its window")
    func recoveryScoreDecays() {
        let context = TestStore.makeContext()
        let fresh = makeRun(
            in: context,
            daysAgo: 0.2 / 24,
            distanceMeters: 20_000,
            durationSeconds: 60,
            type: .longRun
        )
        let stale = makeRun(
            in: context,
            daysAgo: 1.9 / 24,
            distanceMeters: 20_000,
            durationSeconds: 60,
            type: .longRun
        )

        let freshScore = SmartCoachCards.cards(makeContext(runs: [fresh])).first?.score ?? 0
        let staleScore = SmartCoachCards.cards(makeContext(runs: [stale])).first?.score ?? 0
        #expect(freshScore > staleScore)
        // Even late in the window it still beats a routine preparation note.
        #expect(staleScore > 0.25)
    }

    @Test("The strip is capped, and never holds two cards of one kind")
    func stripIsCappedAndUnique() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .longRun, distanceMeters: 22_000)
        let runs = [
            makeRun(in: context, daysAgo: 1, distanceMeters: 25_000),
            makeRun(in: context, daysAgo: 4, distanceMeters: 25_000),
            makeRun(in: context, daysAgo: 9, distanceMeters: 12_000)
        ]

        let cards = SmartCoachCards.cards(makeContext(nextSession: session, runs: runs))
        #expect(cards.count <= SmartCoachCards.defaultLimit)
        #expect(Set(cards.map(\.id)).count == cards.count)

        let capped = SmartCoachCards.cards(makeContext(nextSession: session, runs: runs), limit: 1)
        #expect(capped.count == 1)
        #expect(SmartCoachCards.cards(makeContext(nextSession: session, runs: runs), limit: 0).isEmpty)
    }

    @Test("Ordering does not depend on the order the runs were handed in")
    func inputOrderDoesNotMatter() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .tempo, distanceMeters: 10_000)
        let runs = [
            makeRun(in: context, daysAgo: 1, distanceMeters: 15_000),
            makeRun(in: context, daysAgo: 4, distanceMeters: 15_000),
            makeRun(in: context, daysAgo: 9, distanceMeters: 12_000)
        ]

        let forwards = SmartCoachCards.cards(makeContext(nextSession: session, runs: runs))
        let backwards = SmartCoachCards.cards(
            makeContext(nextSession: session, runs: Array(runs.reversed()))
        )
        #expect(forwards == backwards)
    }

    // MARK: - Signals

    @Test("Heat scores from whichever of temperature and humidity is more extreme")
    func heatFiresOnEither() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .easy, distanceMeters: 8_000)

        let hot = makeRun(in: context, daysAgo: 2)
        hot.weather = weather(feelsLike: 31, humidity: 40)
        let humid = makeRun(in: context, daysAgo: 2)
        humid.weather = weather(feelsLike: 16, humidity: 88)
        let mild = makeRun(in: context, daysAgo: 2)
        mild.weather = weather(feelsLike: 9, humidity: 55)

        #expect(kinds(SmartCoachCards.cards(makeContext(nextSession: session, runs: [hot]))).contains(.heat))
        #expect(kinds(SmartCoachCards.cards(makeContext(nextSession: session, runs: [humid]))).contains(.heat))
        #expect(!kinds(SmartCoachCards.cards(makeContext(nextSession: session, runs: [mild]))).contains(.heat))
    }

    @Test("A hotter day scores higher than a merely warm one")
    func heatScoresWithTemperature() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .easy, distanceMeters: 8_000)

        let warm = makeRun(in: context, daysAgo: 1)
        warm.weather = weather(feelsLike: 23, humidity: 40)
        let scorching = makeRun(in: context, daysAgo: 1)
        scorching.weather = weather(feelsLike: 34, humidity: 40)

        let warmCards = SmartCoachCards.cards(makeContext(nextSession: session, runs: [warm]))
        let hotCards = SmartCoachCards.cards(makeContext(nextSession: session, runs: [scorching]))
        #expect(score(for: .heat, in: hotCards) > score(for: .heat, in: warmCards))
    }

    @Test("An indoor session ignores the weather, and a stale reading is not conditions")
    func heatStaysQuiet() {
        let context = TestStore.makeContext()
        let indoor = makeSession(in: context, type: .easy, distanceMeters: 8_000, location: .indoor)
        let outdoor = makeSession(in: context, type: .easy, distanceMeters: 8_000)

        let hot = makeRun(in: context, daysAgo: 1)
        hot.weather = weather(feelsLike: 31, humidity: 80)

        let stale = makeRun(in: context, daysAgo: Double(SmartCoachCards.heatLookbackDays + 5))
        stale.weather = weather(feelsLike: 31, humidity: 80)
        // Paired with a recent run carrying no weather, so the stale reading is skipped
        // for being stale rather than because a lay-off took the strip.
        let recentWithoutWeather = makeRun(in: context, daysAgo: 1)

        #expect(!kinds(SmartCoachCards.cards(makeContext(nextSession: indoor, runs: [hot]))).contains(.heat))
        #expect(
            !kinds(SmartCoachCards.cards(
                makeContext(nextSession: outdoor, runs: [recentWithoutWeather, stale])
            )).contains(.heat)
        )
    }

    @Test("A run whose second half was slower produces a fade card, scored by the drift")
    func fadeScoresWithDrift() {
        let context = TestStore.makeContext()
        let mild = makeRun(in: context, daysAgo: 1)
        mild.splits = [
            makeSplit(kilometer: 1, paceSecondsPerKm: 300),
            makeSplit(kilometer: 2, paceSecondsPerKm: 300),
            makeSplit(kilometer: 3, paceSecondsPerKm: 318),
            makeSplit(kilometer: 4, paceSecondsPerKm: 322)
        ]
        let severe = makeRun(in: context, daysAgo: 1)
        severe.splits = [
            makeSplit(kilometer: 1, paceSecondsPerKm: 300),
            makeSplit(kilometer: 2, paceSecondsPerKm: 300),
            makeSplit(kilometer: 3, paceSecondsPerKm: 390),
            makeSplit(kilometer: 4, paceSecondsPerKm: 400)
        ]

        let mildScore = score(for: .fade, in: SmartCoachCards.cards(makeContext(runs: [mild])))
        let severeScore = score(for: .fade, in: SmartCoachCards.cards(makeContext(runs: [severe])))
        #expect(mildScore > 0)
        #expect(severeScore > mildScore)
    }

    @Test("An evenly paced run, and too few splits to compare, both stay quiet")
    func fadeStaysQuiet() {
        let context = TestStore.makeContext()
        let even = makeRun(in: context, daysAgo: 1)
        even.splits = (1...6).map { makeSplit(kilometer: $0, paceSecondsPerKm: 300) }
        let short = makeRun(in: context, daysAgo: 1)
        short.splits = [
            makeSplit(kilometer: 1, paceSecondsPerKm: 300),
            makeSplit(kilometer: 2, paceSecondsPerKm: 400)
        ]

        #expect(!kinds(SmartCoachCards.cards(makeContext(runs: [even]))).contains(.fade))
        #expect(!kinds(SmartCoachCards.cards(makeContext(runs: [short]))).contains(.fade))
    }

    @Test("Easy runs sitting on top of the hard ones produce a polarization card")
    func polarizationFires() {
        let context = TestStore.makeContext()
        // 5:12/km easy against 5:00/km tempo — a 4% separation.
        let runs = [
            makeRun(in: context, daysAgo: 2, distanceMeters: 10_000, durationSeconds: 3_120, type: .easy),
            makeRun(in: context, daysAgo: 4, distanceMeters: 10_000, durationSeconds: 3_120, type: .easy),
            makeRun(in: context, daysAgo: 6, distanceMeters: 10_000, durationSeconds: 3_000, type: .tempo)
        ]

        #expect(kinds(SmartCoachCards.cards(makeContext(runs: runs))).contains(.polarization))
    }

    @Test("A properly separated week, and a week with no hard run, both stay quiet")
    func polarizationStaysQuiet() {
        let context = TestStore.makeContext()
        // 6:00/km easy against 4:30/km tempo — a 33% separation.
        let separated = [
            makeRun(in: context, daysAgo: 2, distanceMeters: 10_000, durationSeconds: 3_600, type: .easy),
            makeRun(in: context, daysAgo: 4, distanceMeters: 10_000, durationSeconds: 3_600, type: .easy),
            makeRun(in: context, daysAgo: 6, distanceMeters: 10_000, durationSeconds: 2_700, type: .tempo)
        ]
        let easyOnly = [
            makeRun(in: context, daysAgo: 2, distanceMeters: 10_000, durationSeconds: 3_120, type: .easy),
            makeRun(in: context, daysAgo: 4, distanceMeters: 10_000, durationSeconds: 3_120, type: .easy)
        ]

        #expect(!kinds(SmartCoachCards.cards(makeContext(runs: separated))).contains(.polarization))
        #expect(!kinds(SmartCoachCards.cards(makeContext(runs: easyOnly))).contains(.polarization))
    }

    @Test("Low cadence against the published figure fires while history is thin")
    func cadenceUsesTheGlobalFigureEarly() {
        let context = TestStore.makeContext()
        let runs = (1...3).map { index -> RunWorkout in
            let run = makeRun(in: context, daysAgo: Double(index) * 2)
            run.averageCadenceStepsPerMinute = 152
            return run
        }

        #expect(kinds(SmartCoachCards.cards(makeContext(runs: runs))).contains(.cadence))
    }

    @Test("A runner who has always turned over slowly is not told to fix it")
    func cadenceRespectsAPersonalBaseline() {
        let context = TestStore.makeContext()
        // Twelve runs, all at 156 — below the published 165 but entirely normal for them.
        let runs = (1...12).map { index -> RunWorkout in
            let run = makeRun(in: context, daysAgo: Double(index) * 2)
            run.averageCadenceStepsPerMinute = 156
            return run
        }

        #expect(!kinds(SmartCoachCards.cards(makeContext(runs: runs))).contains(.cadence))
    }

    @Test("A real drop from a healthy baseline does fire, even above the published figure")
    func cadenceFiresOnADropFromNormal() {
        let context = TestStore.makeContext()
        // Historic 182, with the three most recent runs down at 168 — above 165, and a
        // fourteen-point drop from this runner's own normal.
        var runs: [RunWorkout] = (1...3).map { index in
            let run = makeRun(in: context, daysAgo: Double(index) * 2)
            run.averageCadenceStepsPerMinute = 168
            return run
        }
        runs += (4...14).map { index in
            let run = makeRun(in: context, daysAgo: Double(index) * 2)
            run.averageCadenceStepsPerMinute = 182
            return run
        }

        #expect(kinds(SmartCoachCards.cards(makeContext(runs: runs))).contains(.cadence))
    }

    @Test("Runs recorded without a pedometer reading are not counted as zero cadence")
    func cadenceIgnoresMissingReadings() {
        let context = TestStore.makeContext()
        let runs = (1...5).map { makeRun(in: context, daysAgo: Double($0) * 2) }

        #expect(!kinds(SmartCoachCards.cards(makeContext(runs: runs))).contains(.cadence))
    }

    @Test("A near-zero base week does not make any increase a warning")
    func loadNeedsAMeaningfulBase() {
        let context = TestStore.makeContext()
        let runs = [
            makeRun(in: context, daysAgo: 2, distanceMeters: 8_000),
            makeRun(in: context, daysAgo: 9, distanceMeters: 2_000)
        ]

        #expect(!kinds(SmartCoachCards.cards(makeContext(runs: runs))).contains(.load))
    }

    @Test("Holding volume steady says nothing")
    func loadStaysQuietWhenVolumeHolds() {
        let context = TestStore.makeContext()
        let runs = [
            makeRun(in: context, daysAgo: 2, distanceMeters: 15_000),
            makeRun(in: context, daysAgo: 9, distanceMeters: 15_000)
        ]

        #expect(!kinds(SmartCoachCards.cards(makeContext(runs: runs))).contains(.load))
    }

    // MARK: - Body mass

    @Test("A known body mass turns the fuelling ranges into amounts")
    func bodyMassPersonalisesFuelling() {
        let context = TestStore.makeContext()
        let session = makeSession(in: context, type: .longRun, distanceMeters: 22_000, paceBand: 360...360)

        let profile = UserProfile(
            name: "Sam",
            goalRace: .maintainFitness,
            goalFinishTime: 0,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )
        profile.bodyMassKilograms = 72
        context.insert(profile)

        let withMass = SmartCoachCards.cards(makeContext(nextSession: session, profile: profile)).first
        let withoutMass = SmartCoachCards.cards(makeContext(nextSession: session)).first

        #expect(withMass?.kind == .longRunFuel)
        #expect(withoutMass?.kind == .longRunFuel)
        // 72 kg at 0.9 g/kg/h is 65 g an hour.
        #expect(withMass?.message.contains("65 g an hour") == true)
        #expect(withoutMass?.message.contains("30–60 g an hour") == true)
        // Both carry a derivation; only one of them names a weight.
        #expect(withMass?.derivation?.contains("72 kg") == true)
        #expect(withoutMass?.derivation?.contains("kg") == false)
    }

    // MARK: - Helpers

    private func weather(feelsLike: Double, humidity: Double) -> WorkoutWeather {
        WorkoutWeather(
            temperatureCelsius: feelsLike,
            feelsLikeCelsius: feelsLike,
            humidityPercent: humidity,
            windSpeedKmh: 6,
            conditionSymbol: "sun.max.fill",
            conditionDescription: "Clear"
        )
    }

    private func score(for kind: SmartCoachCard.Kind, in cards: [SmartCoachCard]) -> Double {
        cards.first { $0.kind == kind }?.score ?? 0
    }
}
