import Foundation
import SwiftData
import Testing
@testable import Stride

/// Covers NotificationService behaviours that touch persisted state.
@MainActor
struct NotificationServiceTests {

    /// M39: the TestFlight "synced run" QA notification must not write a fake run into
    /// the real store (it previously inserted an unmarked 5 km run that polluted stats
    /// and synced to CloudKit). The tap-to-review flow now rides on the review snapshot.
    @Test("QA synced-run test notification never inserts a run into the store")
    func qaSyncedRunDoesNotPolluteStore() async throws {
        let context = TestStore.makeContext()

        let before = try context.fetch(FetchDescriptor<RunWorkout>()).count
        try await NotificationService.shared.triggerSyncedRunTestNotification(in: context)
        let after = try context.fetch(FetchDescriptor<RunWorkout>()).count

        #expect(before == 0)
        #expect(after == 0)
    }

    // MARK: Morning reminder candidates (M7)

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return calendar.date(from: c)!
    }

    /// A plan holding one week whose workouts are `days` day-offsets from `start`.
    private func makePlan(start: Date, workouts: [ScheduledWorkout]) -> TrainingPlan {
        let plan = TrainingPlan(
            targetRace: .marathon,
            goalTimeSeconds: 4 * 3_600,
            startDate: start,
            endDate: start.adding(days: 7 * 18)
        )
        let week = TrainingWeek(weekNumber: 1, startDate: start, phase: .base, targetDistanceKm: 40)
        week.workouts = workouts
        plan.weeks = [week]
        return plan
    }

    @Test("Morning reminders cap at the soonest workouts, below the iOS 64-pending limit (M7)")
    func morningRemindersCappedAtSoonest() {
        // An 18-week marathon plan schedules ~100 non-rest workouts; iOS silently
        // keeps only 64 pending requests, dropping the tail of the plan.
        let now = date(2026, 7, 15, 12, 0)
        let workouts = (1...100).map { offset in
            ScheduledWorkout(scheduledDate: date(2026, 7, 15).adding(days: offset), workoutType: .easy)
        }
        let plan = makePlan(start: date(2026, 7, 15), workouts: workouts.shuffled())

        let candidates = NotificationService.morningReminderCandidates(
            for: plan, now: now, calendar: calendar
        )

        #expect(candidates.count == NotificationService.maxScheduledMorningReminders)
        #expect(NotificationService.maxScheduledMorningReminders < 64)
        // Soonest-first: the cap must drop the far end of the plan, not the near end.
        let dates = candidates.map(\.scheduledDate)
        #expect(dates == dates.sorted())
        #expect(dates.last! <= date(2026, 7, 15).adding(days: NotificationService.maxScheduledMorningReminders))
    }

    @Test("Completed, rest, and past workouts get no morning reminder")
    func morningReminderFiltering() {
        let now = date(2026, 7, 15, 12, 0)

        let past = ScheduledWorkout(scheduledDate: date(2026, 7, 14), workoutType: .easy)
        let completed = ScheduledWorkout(scheduledDate: date(2026, 7, 17), workoutType: .tempo)
        completed.isCompleted = true
        let rest = ScheduledWorkout(scheduledDate: date(2026, 7, 18), workoutType: .rest)
        let upcoming = ScheduledWorkout(scheduledDate: date(2026, 7, 19), workoutType: .longRun)

        let plan = makePlan(start: date(2026, 7, 13), workouts: [past, completed, rest, upcoming])
        let candidates = NotificationService.morningReminderCandidates(
            for: plan, now: now, calendar: calendar
        )

        #expect(candidates.count == 1)
        #expect(candidates.first === upcoming)
    }

    @Test("A same-day workout is included only before its 8 AM fire time")
    func sameDayWorkoutRespectsFireTime() {
        let workout = ScheduledWorkout(scheduledDate: date(2026, 7, 15), workoutType: .easy)
        let plan = makePlan(start: date(2026, 7, 15), workouts: [workout])

        let beforeEight = NotificationService.morningReminderCandidates(
            for: plan, now: date(2026, 7, 15, 7, 0), calendar: calendar
        )
        let afterEight = NotificationService.morningReminderCandidates(
            for: plan, now: date(2026, 7, 15, 9, 0), calendar: calendar
        )

        #expect(beforeEight.count == 1)
        #expect(afterEight.isEmpty)
    }

    @Test("The morning reminder fires at the runner's chosen time, not a fixed 8 AM")
    func morningReminderHonoursChosenTime() {
        let workout = ScheduledWorkout(scheduledDate: date(2026, 7, 15, 14, 0), workoutType: .easy)

        let fire = NotificationService.morningFireDate(for: workout, calendar: calendar, minuteOfDay: 6 * 60 + 45)

        #expect(fire == date(2026, 7, 15, 6, 45))
        // And the candidate filter uses the same time: at 07:00 a 06:45 reminder has gone.
        let plan = makePlan(start: date(2026, 7, 15), workouts: [workout])
        #expect(NotificationService.morningReminderCandidates(
            for: plan, now: date(2026, 7, 15, 7, 0), calendar: calendar, minuteOfDay: 6 * 60 + 45
        ).isEmpty)
    }

    @Test("The morning reminder names the session's distance when it has one")
    func morningReminderBodyCarriesDistance() {
        let withDistance = ScheduledWorkout(scheduledDate: date(2026, 7, 15), workoutType: .tempo)
        withDistance.targetDistanceMeters = 8_000
        let withoutDistance = ScheduledWorkout(scheduledDate: date(2026, 7, 15), workoutType: .strength)

        let body = NotificationService.morningReminderBody(for: withDistance, unit: .metric)
        let fallback = NotificationService.morningReminderBody(for: withoutDistance, unit: .metric)

        #expect(body.contains(WorkoutType.tempo.localizedName))
        #expect(body.contains(8_000.0.distanceString(unit: .metric)))
        #expect(fallback.contains(WorkoutType.strength.localizedName))
    }

    @Test("A snooze lands an hour later, and is dropped when that would be tomorrow")
    func snoozeStaysWithinTheDay() {
        let evening = date(2026, 7, 15, 18, 0)
        #expect(NotificationService.snoozedFireDate(now: evening, calendar: calendar) == date(2026, 7, 15, 19, 0))

        let lateNight = date(2026, 7, 15, 23, 30)
        #expect(NotificationService.snoozedFireDate(now: lateNight, calendar: calendar) == nil)
    }

    @Test("The background refresh asks for the next 16:00, today's if it is still ahead")
    func backgroundRefreshAsksForTheNextAfternoon() {
        let morning = date(2026, 7, 15, 9, 0)
        let evening = date(2026, 7, 15, 20, 0)

        #expect(NotificationRefreshService.nextBackgroundRefreshDate(now: morning, calendar: calendar)
            == date(2026, 7, 15, NotificationRefreshService.backgroundRefreshHour, 0))
        #expect(NotificationRefreshService.nextBackgroundRefreshDate(now: evening, calendar: calendar)
            == date(2026, 7, 16, NotificationRefreshService.backgroundRefreshHour, 0))
    }

    @Test("A stored reminder time is clamped into one day, and missing means 8 AM")
    func reminderTimeIsClamped() {
        #expect(AppSettings.minuteOfDay(nil) == 8 * 60)
        #expect(AppSettings.minuteOfDay(-5) == 0)
        #expect(AppSettings.minuteOfDay(5_000) == 24 * 60 - 1)
        #expect(AppSettings.minuteOfDay(405) == 405)
    }

    // MARK: Review-snapshot pruning (S3)

    /// Stale review snapshots (full run copies in UserDefaults) for runs that have
    /// since imported into the store must be removed, while a snapshot for a run
    /// still absent from the store is preserved as the tap-to-review fallback.
    @Test("Pruning removes snapshots for imported runs and keeps still-pending ones")
    func pruneReviewSnapshotsDropsImportedRuns() throws {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let importedID = UUID()
        let pendingID = UUID()
        let prefix = "syncedRunReviewSnapshot."
        defaults.set(Data([0x1]), forKey: "\(prefix)\(importedID.uuidString)")
        defaults.set(Data([0x2]), forKey: "\(prefix)\(pendingID.uuidString)")
        // An unrelated key must be untouched.
        defaults.set("keep", forKey: "unrelated.key")

        NotificationService.pruneReviewSnapshots(storedRunIDs: [importedID], in: defaults)

        #expect(defaults.data(forKey: "\(prefix)\(importedID.uuidString)") == nil)
        #expect(defaults.data(forKey: "\(prefix)\(pendingID.uuidString)") != nil)
        #expect(defaults.string(forKey: "unrelated.key") == "keep")
    }

    /// "Reset All Data" has to drop *every* snapshot, including ones for runs that
    /// never imported — otherwise the next launch re-inserts a run the user just
    /// deleted from the snapshot fallback (N11).
    @Test("Reset clears the pending-review pointer and every snapshot")
    func clearAllReviewStateRemovesPointerAndSnapshots() throws {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pendingID = UUID()
        let prefix = "syncedRunReviewSnapshot."
        defaults.set(Data([0x1]), forKey: "\(prefix)\(UUID().uuidString)")
        defaults.set(Data([0x2]), forKey: "\(prefix)\(pendingID.uuidString)")
        defaults.set(pendingID.uuidString, forKey: NotificationService.pendingReviewWorkoutIDKey)
        defaults.set("keep", forKey: "unrelated.key")

        NotificationService.clearAllReviewState(in: defaults)

        let remaining = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        #expect(remaining.isEmpty)
        #expect(defaults.string(forKey: NotificationService.pendingReviewWorkoutIDKey) == nil)
        #expect(defaults.string(forKey: "unrelated.key") == "keep")
    }
}
