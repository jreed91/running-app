import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers the coach card reaching the widget extension and App Intents.
///
/// The dashboard runs `SmartCoachCards` directly and so do intents, but the widget cannot:
/// it is a separate process with no SwiftData, so the app publishes the winning card into
/// `WidgetSnapshot`. That hop is where this can go wrong, and it goes wrong quietly — a
/// glance that carries a clock is still *correct* when it is written and only becomes a
/// lie later, on a screen nobody is looking at yet.
@MainActor
struct CoachTipSurfacesTests {

    /// Fixed anchor: 2023-11-14 22:13:20 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Fixtures

    private func makePlan(
        in context: ModelContext,
        sessions: [(offsetDays: Int, type: WorkoutType, distance: Double?)],
        raceDate: Date? = nil
    ) throws -> TrainingPlan {
        let start = Calendar.current.startOfDay(for: now)
        let plan = TrainingPlan(
            targetRace: .marathon,
            goalTimeSeconds: 14_400,
            raceDate: raceDate,
            startDate: start,
            endDate: start.addingTimeInterval(30 * 86_400)
        )
        plan.isActive = true
        context.insert(plan)

        let week = TrainingWeek(weekNumber: 1, startDate: start, phase: .base, targetDistanceKm: 40)
        context.insert(week)
        week.plan = plan

        for session in sessions {
            let workout = ScheduledWorkout(
                scheduledDate: start.addingTimeInterval(Double(session.offsetDays) * 86_400),
                workoutType: session.type,
                targetDistanceMeters: session.distance
            )
            context.insert(workout)
            workout.week = week
        }
        try context.save()
        return plan
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

    // MARK: - The glance contract

    /// The rule the widget depends on. A glance is written when the app runs and read
    /// whenever the runner looks at their Home Screen, so anything in it that counts —
    /// minutes, days, "tomorrow" — is a lie waiting to happen.
    @Test("No glance contains a relative time word", arguments: [UnitPreference.metric, .imperial])
    func glancesCarryNoClock(unit: UnitPreference) throws {
        let context = TestStore.makeContext()
        let forbidden = [
            "minutes ago", "hours ago", "days ago", "days since",
            "today", "tomorrow", "yesterday", "this week", "last week"
        ]

        for card in try everyKindOfCard(in: context, unit: unit) {
            let glance = card.glance.lowercased()
            for word in forbidden {
                #expect(
                    !glance.contains(word),
                    "\(card.kind.rawValue) glance contains a relative time: \"\(card.glance)\""
                )
            }
        }
    }

    @Test(
        "Every glance is shorter than its dashboard message and is a real sentence",
        arguments: [UnitPreference.metric, .imperial]
    )
    func glancesAreShortAndPresent(unit: UnitPreference) throws {
        let context = TestStore.makeContext()
        for card in try everyKindOfCard(in: context, unit: unit) {
            #expect(!card.glance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(card.glance.count < card.message.count, "\(card.kind.rawValue) glance is not shorter")
            // A widget line, not a paragraph.
            #expect(card.glance.count <= 90, "\(card.kind.rawValue) glance is \(card.glance.count) characters")
        }
    }

    /// The bug this suite missed the first time: every fixture ran metric, so a card
    /// pouring millilitres at a runner who set miles looked perfectly correct.
    @Test("No imperial card quotes a metric volume or weight")
    func imperialCardsCarryNoMetricUnits() throws {
        let context = TestStore.makeContext()
        for card in try everyKindOfCard(in: context, unit: .imperial) {
            for text in [card.message, card.glance] {
                #expect(!text.contains(" ml"), "\(card.kind.rawValue) quotes millilitres: \(text)")
                #expect(!text.contains("°C"), "\(card.kind.rawValue) quotes Celsius: \(text)")
            }
            // Kilograms survive only inside the derivation's bracketed basis, never in
            // anything the runner is being asked to act on.
            #expect(!card.message.contains(" kg"), "\(card.kind.rawValue) message quotes kilograms")
            #expect(!card.glance.contains(" kg"), "\(card.kind.rawValue) glance quotes kilograms")
        }
    }

    // MARK: - Expiry

    @Test("A refuel card expires at the end of its window, anchored to the run's finish")
    func refuelExpires() {
        let context = TestStore.makeContext()
        // Started 30 minutes ago, ran for 20 — finished 10 minutes back.
        let run = makeRun(
            in: context,
            daysAgo: 0.5 / 24,
            distanceMeters: 15_000,
            durationSeconds: 1_200,
            type: .longRun
        )

        let card = SmartCoachCards.cards(makeContext(runs: [run]), limit: 1).first
        #expect(card?.kind == .refuel)

        let finish = run.date.addingTimeInterval(run.durationSeconds)
        let expected = finish.addingTimeInterval(CoachSituation.recoveryWindowSeconds)
        #expect(card?.expiresAt == expected)
        #expect(card?.isValid(asOf: now) == true)
        #expect(card?.isValid(asOf: expected.addingTimeInterval(60)) == false)
    }

    /// The reload-budget trap. An expiry computed as "now plus two hours" would move on
    /// every write, so every foreground would produce a different snapshot and spend one
    /// of WidgetKit's budgeted reloads.
    @Test("A refuel card's expiry does not move between writes")
    func refuelExpiryIsStableAcrossWrites() {
        let context = TestStore.makeContext()
        let run = makeRun(
            in: context,
            daysAgo: 0.5 / 24,
            distanceMeters: 15_000,
            durationSeconds: 1_200,
            type: .longRun
        )

        let first = SmartCoachCards.cards(makeContext(runs: [run]), limit: 1).first
        let later = SmartCoachCards.cards(
            SmartCoachCards.Context(
                nextSession: nil,
                recentRuns: [run],
                profile: nil,
                dayState: .noPlan,
                unit: .metric,
                now: now.addingTimeInterval(600)
            ),
            limit: 1
        ).first

        #expect(first?.expiresAt == later?.expiresAt)
    }

    @Test("A card with no expiry is valid whenever it is read")
    func cardsWithoutExpiryNeverGoOff() {
        let card = SmartCoachCards.cards(makeContext(dayState: .noPlan), limit: 1).first
        #expect(card?.kind == .noPlan)
        #expect(card?.expiresAt == nil)
        #expect(card?.isValid(asOf: now.addingTimeInterval(86_400 * 30)) == true)
    }

    // MARK: - The snapshot hop

    @Test("The snapshot carries the same card the dashboard would show")
    func snapshotMatchesTheDashboard() throws {
        let context = TestStore.makeContext()
        let plan = try makePlan(in: context, sessions: [(1, .longRun, 22_000)])
        let runs = [makeRun(in: context, daysAgo: 2)]

        let tip = WidgetSnapshotBuilder.coachTip(
            plan: plan,
            runs: runs,
            profile: nil,
            unit: .metric,
            now: now
        )

        let dashboard = SmartCoachCards.cards(
            SmartCoachCards.Context(
                nextSession: ScheduledDayResolver.upcomingSession(onOrAfter: now, in: plan),
                recentRuns: runs,
                profile: nil,
                dayState: ScheduledDayResolver.dayState(on: now, in: plan),
                unit: .metric,
                now: now
            ),
            limit: 1
        ).first

        #expect(tip != nil)
        #expect(tip?.title == dashboard?.title)
        // The snapshot ships the glance, never the dashboard's long copy.
        #expect(tip?.message == dashboard?.glance)
        #expect(tip?.message != dashboard?.message)
        #expect(tip?.categoryLabel == dashboard?.category.label)
    }

    @Test("A retired plan does not reach the Home Screen")
    func retiredPlanIsIgnored() throws {
        let context = TestStore.makeContext()
        let plan = try makePlan(in: context, sessions: [(1, .longRun, 22_000)])
        plan.isActive = false
        try context.save()

        let tip = WidgetSnapshotBuilder.coachTip(
            plan: plan,
            runs: [],
            profile: nil,
            unit: .metric,
            now: now
        )
        // Falls back to the no-plan card rather than advising on a plan that was replaced.
        #expect(tip?.title != nil)
        #expect(tip?.symbolName == WidgetSnapshotBuilder.symbolName(for: .noPlan))
    }

    @Test("Every kind maps to a symbol and a tone maps to a palette name")
    func presentationIsTotal() {
        for kind in SmartCoachCard.Kind.allCases {
            #expect(!WidgetSnapshotBuilder.symbolName(for: kind).isEmpty)
        }
        #expect(WidgetSnapshotBuilder.tint(for: .positive) == .success)
        #expect(WidgetSnapshotBuilder.tint(for: .neutral) == .brand)
        #expect(WidgetSnapshotBuilder.tint(for: .caution) == .tempo)
    }

    @Test("The tip survives a round trip through the snapshot file's coding")
    func tipSurvivesCoding() throws {
        let snapshot = WidgetSnapshot.sample(now: now)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded.coachTip == snapshot.coachTip)
        #expect(decoded == snapshot)
    }

    /// A snapshot written before `coachTip` existed still has to decode — the app is the
    /// only writer, but a widget can be woken against a file the previous build left.
    @Test("A snapshot with no coach tip still decodes")
    func olderSnapshotsStillDecode() throws {
        var snapshot = WidgetSnapshot.sample(now: now)
        snapshot.coachTip = nil
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded.coachTip == nil)
    }

    @Test("An expired tip reports itself invalid so the widget can fall back")
    func snapshotTipExpiry() {
        let tip = WidgetSnapshot.CoachTip(
            title: "Refuel while the window's open",
            message: "70 g of carbohydrate with 21 g of protein within the hour.",
            categoryLabel: "FUEL",
            symbolName: "heart.fill",
            tint: .success,
            expiresAt: now.addingTimeInterval(3_600)
        )
        #expect(tip.isValid(asOf: now))
        #expect(!tip.isValid(asOf: now.addingTimeInterval(7_200)))

        var open = tip
        open.expiresAt = nil
        #expect(open.isValid(asOf: now.addingTimeInterval(86_400 * 365)))
    }

    // MARK: - Siri

    @Test("Siri speaks the glance, not the dashboard paragraph")
    func intentDialogUsesTheGlance() {
        let context = TestStore.makeContext()
        let run = makeRun(
            in: context,
            daysAgo: 0.5 / 24,
            distanceMeters: 15_000,
            durationSeconds: 1_200,
            type: .longRun
        )
        guard let card = SmartCoachCards.cards(makeContext(runs: [run]), limit: 1).first else {
            Issue.record("expected a card")
            return
        }

        #expect(CoachTipIntent.dialogText(for: card) == card.glance)
        #expect(CoachTipIntent.dialogText(for: card) != card.message)
    }

    @Test("With nothing to say Siri answers rather than falling silent")
    func intentDialogHasAnEmptyAnswer() {
        let answer = CoachTipIntent.dialogText(for: nil)
        #expect(!answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Helpers

    /// One card of every kind the selection can produce, so the contracts above are
    /// checked against all of them rather than the handful a single fixture happens to hit.
    private func everyKindOfCard(
        in context: ModelContext,
        unit: UnitPreference = .metric
    ) throws -> [SmartCoachCard] {
        var cards: [SmartCoachCard] = []

        func add(_ built: [SmartCoachCard]) {
            for card in built where !cards.contains(where: { $0.kind == card.kind }) {
                cards.append(card)
            }
        }

        // Race day and race week.
        let racer = UserProfile(
            name: "Sam",
            goalRace: .marathon,
            goalFinishTime: 14_400,
            raceDate: now,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )
        context.insert(racer)
        add(SmartCoachCards.cards(makeContext(profile: racer, unit: unit)))
        racer.raceDate = now.addingTimeInterval(3 * 86_400)
        add(SmartCoachCards.cards(makeContext(profile: racer, unit: unit)))

        // Lay-off, and the recovery window.
        add(SmartCoachCards.cards(makeContext(runs: [makeRun(in: context, daysAgo: 21)], unit: unit)))
        add(SmartCoachCards.cards(makeContext(runs: [
            makeRun(in: context, daysAgo: 0.5 / 24, distanceMeters: 15_000, durationSeconds: 1_200, type: .longRun)
        ], unit: unit)))

        // The three session shapes plus a gym day.
        let shapes: [(WorkoutType, Double?)] = [
            (.longRun, 22_000), (.tempo, 10_000), (.easy, 6_000), (.strength, nil)
        ]
        for (type, distance) in shapes {
            let session = ScheduledWorkout(
                scheduledDate: now.addingTimeInterval(86_400),
                workoutType: type,
                targetDistanceMeters: distance
            )
            context.insert(session)
            add(SmartCoachCards.cards(makeContext(nextSession: session, unit: unit)))
        }

        // The four empty states.
        for state: ScheduledDayResolver.DayState in [
            .rest, .beforePlanStart(daysUntilStart: 3), .outsidePlan, .noPlan
        ] {
            add(SmartCoachCards.cards(makeContext(dayState: state, unit: unit)))
        }

        // The signals.
        add(SmartCoachCards.cards(makeContext(runs: [
            makeRun(in: context, daysAgo: 1, distanceMeters: 25_000),
            makeRun(in: context, daysAgo: 4, distanceMeters: 25_000),
            makeRun(in: context, daysAgo: 9, distanceMeters: 12_000)
        ], unit: unit)))

        let hot = makeRun(in: context, daysAgo: 1)
        hot.weather = WorkoutWeather(
            temperatureCelsius: 31,
            feelsLikeCelsius: 33,
            humidityPercent: 80,
            windSpeedKmh: 5,
            conditionSymbol: "sun.max.fill",
            conditionDescription: "Hot"
        )
        let outdoor = ScheduledWorkout(
            scheduledDate: now.addingTimeInterval(86_400),
            workoutType: .easy,
            targetDistanceMeters: 8_000
        )
        context.insert(outdoor)
        add(SmartCoachCards.cards(makeContext(nextSession: outdoor, runs: [hot], unit: unit)))

        let faded = makeRun(in: context, daysAgo: 1)
        faded.splits = [300, 300, 390, 400].enumerated().map { index, pace in
            Split(
                kilometer: index + 1,
                paceSecondsPerKm: pace,
                heartRate: nil,
                elevationGainMeters: 0,
                cumulativeDistanceMeters: Double(index + 1) * 1_000
            )
        }
        add(SmartCoachCards.cards(makeContext(runs: [faded], unit: unit)))

        add(SmartCoachCards.cards(makeContext(runs: [
            makeRun(in: context, daysAgo: 2, distanceMeters: 10_000, durationSeconds: 3_120, type: .easy),
            makeRun(in: context, daysAgo: 4, distanceMeters: 10_000, durationSeconds: 3_120, type: .easy),
            makeRun(in: context, daysAgo: 6, distanceMeters: 10_000, durationSeconds: 3_000, type: .tempo)
        ], unit: unit)))

        let slow = (1...3).map { index -> RunWorkout in
            let run = makeRun(in: context, daysAgo: Double(index) * 2)
            run.averageCadenceStepsPerMinute = 152
            return run
        }
        add(SmartCoachCards.cards(makeContext(runs: slow, unit: unit)))

        // Every kind should be reachable; if one is not, the contracts below would
        // silently stop covering it.
        let covered = Set(cards.map(\.kind))
        for kind in SmartCoachCard.Kind.allCases {
            #expect(covered.contains(kind), "no fixture produces a \(kind.rawValue) card")
        }
        return cards
    }
}
