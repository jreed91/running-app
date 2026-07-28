import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers `NextUpBriefing`, the content of the dashboard's "Up next" card.
///
/// The card is now a standing part of the screen rather than something shown only on
/// empty days, so what it says has to hold up for every kind of session the plan can
/// prescribe — including the ones that set no distance and no pace band.
@MainActor
struct NextUpBriefingTests {

    /// Fixed anchor: 2023-11-14 22:13:20 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeWorkout(
        in context: ModelContext,
        type: WorkoutType = .easy,
        daysFromNow: Int = 1,
        distanceMeters: Double? = nil,
        paceBand: ClosedRange<Double>? = nil,
        notes: String? = nil
    ) -> ScheduledWorkout {
        let workout = ScheduledWorkout(
            scheduledDate: now.addingTimeInterval(Double(daysFromNow) * 86_400),
            workoutType: type,
            targetDistanceMeters: distanceMeters,
            targetPaceLowerBound: paceBand?.lowerBound,
            targetPaceUpperBound: paceBand?.upperBound,
            notes: notes
        )
        context.insert(workout)
        return workout
    }

    // MARK: - Day phrasing

    @Test("Today and tomorrow are named rather than dated")
    func nearDaysAreNamed() {
        #expect(NextUpBriefing.dayPhrase(for: now, now: now) == "Today")
        #expect(NextUpBriefing.dayPhrase(for: now.addingTimeInterval(86_400), now: now) == "Tomorrow")
    }

    @Test("A day inside the coming week reads as its weekday")
    func nearWeekIsAWeekday() {
        let date = now.addingTimeInterval(4 * 86_400)
        let phrase = NextUpBriefing.dayPhrase(for: date, now: now)
        #expect(phrase == date.formatted(.dateTime.weekday(.wide)))
    }

    @Test("Beyond a week a bare weekday stops meaning anything, so the date is spelled out")
    func farDaysAreDated() {
        let date = now.addingTimeInterval(12 * 86_400)
        let phrase = NextUpBriefing.dayPhrase(for: date, now: now)
        #expect(phrase == date.formatted(.dateTime.weekday(.abbreviated).month().day()))
    }

    // MARK: - Duration estimates

    @Test("Distance and a pace band multiply out to an estimated time")
    func durationComesFromDistanceAndPace() {
        let context = TestStore.makeContext()
        // 10 km at 5:00–6:00 per km averages 5:30, so 55 minutes.
        let workout = makeWorkout(
            in: context,
            type: .easy,
            distanceMeters: 10_000,
            paceBand: 300...360
        )
        let seconds = NextUpBriefing.estimatedDurationSeconds(for: workout)
        #expect(seconds == 3_300)
    }

    @Test("A single pace bound is used when the plan set no range")
    func durationUsesASingleBound() {
        let context = TestStore.makeContext()
        let workout = makeWorkout(in: context, distanceMeters: 5_000)
        workout.targetPaceLowerBound = 360
        #expect(NextUpBriefing.estimatedDurationSeconds(for: workout) == 1_800)
    }

    @Test("A structured session's own estimate wins over distance times pace")
    func structureEstimateWins() {
        let context = TestStore.makeContext()
        let workout = makeWorkout(
            in: context,
            type: .interval,
            distanceMeters: 10_000,
            paceBand: 300...300
        )
        workout.workoutStructure = WorkoutStructure(
            warmup: WorkoutSegment(
                distanceMeters: 2_000,
                durationSeconds: nil,
                targetPaceSecondsPerKm: 360,
                label: "Warm-up"
            ),
            mainSets: [],
            cooldown: WorkoutSegment(
                distanceMeters: 2_000,
                durationSeconds: nil,
                targetPaceSecondsPerKm: 360,
                label: "Cool-down"
            ),
            totalEstimatedDistanceMeters: 10_000,
            totalEstimatedDurationSeconds: 4_200
        )
        #expect(NextUpBriefing.estimatedDurationSeconds(for: workout) == 4_200)
    }

    @Test("No distance and no pace means no estimate rather than a made-up one")
    func noPrescriptionMeansNoEstimate() {
        let context = TestStore.makeContext()
        let workout = makeWorkout(in: context, type: .strength)
        #expect(NextUpBriefing.estimatedDurationSeconds(for: workout) == nil)
    }

    @Test("Durations round to minutes below the hour and to hours and minutes above it")
    func durationTextIsCoarse() {
        #expect(NextUpBriefing.approximateDurationText(seconds: 2_880) == "~48 min")
        #expect(NextUpBriefing.approximateDurationText(seconds: 3_600) == "~1 h")
        #expect(NextUpBriefing.approximateDurationText(seconds: 5_100) == "~1 h 25 min")
        // Below a minute there is nothing worth printing.
        #expect(NextUpBriefing.approximateDurationText(seconds: 30) == nil)
    }

    // MARK: - Whole briefing

    @Test("A fully prescribed session fills every field")
    func fullBriefing() {
        let context = TestStore.makeContext()
        let workout = makeWorkout(
            in: context,
            type: .longRun,
            daysFromNow: 1,
            distanceMeters: 18_000,
            paceBand: 370...400,
            notes: "Keep it easy. Practise your fuelling if over 90 minutes."
        )

        let briefing = NextUpBriefing.make(for: workout, unit: .metric, now: now)
        #expect(briefing.title == WorkoutType.longRun.localizedName)
        #expect(briefing.dayPhrase == "Tomorrow")
        #expect(briefing.distanceText == "18.0 km")
        #expect(briefing.paceText == "6:10–6:40 /km")
        #expect(briefing.durationText != nil)
        #expect(briefing.note == "Keep it easy")
        #expect(briefing.isToday == false)
    }

    @Test("A session with no prescription leaves the metric fields empty rather than dashed")
    func sparseBriefing() {
        let context = TestStore.makeContext()
        let workout = makeWorkout(in: context, type: .strength, daysFromNow: 3)

        let briefing = NextUpBriefing.make(for: workout, unit: .metric, now: now)
        #expect(briefing.distanceText == nil)
        #expect(briefing.paceText == nil)
        #expect(briefing.durationText == nil)
        #expect(briefing.note == nil)
    }

    @Test("Imperial runners get miles and per-mile paces")
    func imperialBriefing() {
        let context = TestStore.makeContext()
        let workout = makeWorkout(
            in: context,
            type: .tempo,
            distanceMeters: 8_046.72,        // exactly five miles
            paceBand: 300...300
        )

        let briefing = NextUpBriefing.make(for: workout, unit: .imperial, now: now)
        #expect(briefing.distanceText == "5.0 mi")
        #expect(briefing.paceText == "8:02 /mi")
    }

    @Test("Today's session is flagged as today")
    func todayIsFlagged() {
        let context = TestStore.makeContext()
        let workout = makeWorkout(in: context, type: .easy, daysFromNow: 0)

        let briefing = NextUpBriefing.make(for: workout, unit: .metric, now: now)
        #expect(briefing.isToday)
        #expect(briefing.dayPhrase == "Today")
    }
}
