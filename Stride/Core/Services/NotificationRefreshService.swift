import BackgroundTasks
import Foundation
import SwiftData

// MARK: - NotificationPreferences

/// The settings every notification decision reads, as a value.
///
/// A value rather than an `AppSettings` because two of the three callers have none: a
/// background HealthKit sync and a background app refresh both run before any view has
/// built the observable settings object. `AppSettings.notificationPreferences` and
/// `AppSettings.syncedNotificationPreferences()` produce one either way.
struct NotificationPreferences: Equatable, Sendable {
    var morningReminderEnabled: Bool
    var trainingNudgesEnabled: Bool
    var heatAdaptationEnabled: Bool
    var unit: UnitPreference
    var weeklyGoalMeters: Double
}

// MARK: - NotificationRefreshService

/// Re-arms every scheduled notification against the store as it stands now.
///
/// Every notification Stride sends except "Run Synced" is decided against "what has
/// happened so far" — tonight's streak, tomorrow's forecast, this week's runs — and the
/// app has no server to push them, so they are only ever as current as the last time
/// this ran. It used to live on `ContentView`, which meant it ran only while a scene was
/// on screen. Pulled out here so the two things that run without a scene can call it
/// too: the HealthKit import of a run recorded on the Watch, and the daily background
/// app refresh (`backgroundRefreshIdentifier`).
@MainActor
final class NotificationRefreshService {

    private let notificationService: NotificationService
    private let heatAdvisoryService: HeatAdvisoryService
    private let context: ModelContext
    private let defaults: UserDefaults

    init(
        notificationService: NotificationService,
        heatAdvisoryService: HeatAdvisoryService,
        context: ModelContext,
        defaults: UserDefaults = .standard
    ) {
        self.notificationService = notificationService
        self.heatAdvisoryService = heatAdvisoryService
        self.context = context
        self.defaults = defaults
    }

    // MARK: Refresh

    /// Everything a foreground re-arms: the morning reminders' sliding window, tomorrow's
    /// heat advisory, tonight's nudge and the Sunday recap. For the background refresh,
    /// which has no `ContentView` to do it piecemeal.
    func refreshAll(preferences: NotificationPreferences) async {
        let plan = activePlan()
        if let plan {
            if preferences.morningReminderEnabled {
                await notificationService.scheduleMorningReminders(for: plan)
            } else {
                await notificationService.cancelAllMorningReminders()
            }
        }
        await refreshHeatAdvisory(plan: plan, preferences: preferences)
        await refreshTrainingNudges(plan: plan, preferences: preferences)
    }

    /// Recomputes tonight's nudge, tomorrow's streak nudge and, on a Sunday, the recap (A9).
    ///
    /// Every decision is `TrainingNudgePolicy`'s; this reads the three things it needs —
    /// the runner's recent runs, the active plan, the weekly goal — and hands them over.
    /// The run fetch is bounded at `TrainingNudgePolicy.streakRunSampleSize`, through
    /// `runsOnlyDescriptor` rather than filtered afterwards so a runner who walks does
    /// not get a shorter sample than one who doesn't (N38).
    func refreshTrainingNudges(plan: TrainingPlan?, preferences: NotificationPreferences) async {
        guard preferences.trainingNudgesEnabled else {
            await notificationService.cancelTrainingNudges(includingLog: true)
            return
        }

        let runs = (try? context.fetch(
            RunWorkout.runsOnlyDescriptor(
                sortBy: [SortDescriptor(\RunWorkout.date, order: .reverse)],
                fetchLimit: TrainingNudgePolicy.streakRunSampleSize
            )
        )) ?? []

        let streak = StreakGoalService.streak(for: runs)

        if let nudge = TrainingNudgePolicy.eveningNudge(
            streak: streak,
            plan: plan,
            missedPromptFlaggedAt: missedWorkoutPromptFlaggedAt
        ) {
            await notificationService.scheduleEveningNudge(nudge)
        } else {
            // Nothing to say tonight — and something queued from this morning may now be
            // wrong, which is the case this branch exists for: the run that ended the
            // streak nudge was logged at lunchtime.
            notificationService.cancelTrainingNudge(.streak)
            notificationService.cancelTrainingNudge(.missedWorkouts)
        }

        // Today's run is in, so tonight has nothing to say about the streak — but
        // tomorrow will, and the runner who skips tomorrow is likely not to open the
        // app tomorrow either.
        if let tomorrow = TrainingNudgePolicy.tomorrowStreakNudge(for: streak) {
            await notificationService.scheduleTomorrowStreakNudge(tomorrow)
        }

        // Re-armed on every pass rather than once, so a run imported on Sunday afternoon
        // is in the 19:00 numbers instead of being left out of them.
        if let recap = TrainingNudgePolicy.weeklyRecap(for: runs, goalMeters: preferences.weeklyGoalMeters) {
            await notificationService.scheduleWeeklyRecap(recap, unit: preferences.unit)
        }
    }

    /// Re-reads tomorrow's forecast and re-arms the evening heat banner.
    ///
    /// Runs the same fetch the advisory's location and start-hour heuristics need — the
    /// newest twenty runs, walks excluded, because "when and where does this person run"
    /// is a training question (N38).
    func refreshHeatAdvisory(plan: TrainingPlan?, preferences: NotificationPreferences) async {
        let recentRuns = (try? context.fetch(
            RunWorkout.runsOnlyDescriptor(
                sortBy: [SortDescriptor(\RunWorkout.date, order: .reverse)],
                fetchLimit: 20
            )
        )) ?? []

        await heatAdvisoryService.refresh(
            plan: plan,
            recentRuns: recentRuns,
            isEnabled: preferences.heatAdaptationEnabled,
            unit: preferences.unit
        )
    }

    /// The newest active plan — the one `ContentView`'s `activePlans.first` names, and the
    /// one launch-time dedup keeps.
    func activePlan() -> TrainingPlan? {
        var descriptor = FetchDescriptor<TrainingPlan>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\TrainingPlan.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The dashboard recovery card's once-a-week dismissal, which the missed-workout push
    /// honours too. Same key as `DashboardView`'s `@AppStorage`.
    private var missedWorkoutPromptFlaggedAt: Date? {
        let interval = defaults.double(forKey: MissedWorkoutDetector.promptFlaggedDateKey)
        return interval == 0 ? nil : Date(timeIntervalSince1970: interval)
    }

    // MARK: Background app refresh

    /// The `BGAppRefreshTask` that re-arms the notifications once a day without the app
    /// being opened. Must match `BGTaskSchedulerPermittedIdentifiers` in `project.yml`.
    static let backgroundRefreshIdentifier = "com.running.stride.notification-refresh"

    /// Ask for the refresh from 16:00: ahead of the 18:00 evening slot, so the streak
    /// nudge, the missed-workout push and the heat advisory are armed for it, and late
    /// enough that "you haven't run today" is mostly settled. iOS treats the date as a
    /// floor and picks the moment itself, so this is a request rather than a schedule.
    static let backgroundRefreshHour = 16

    /// The next 16:00 strictly after `now`. Pure so it is testable.
    static func nextBackgroundRefreshDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = backgroundRefreshHour
        components.minute = 0
        components.second = 0
        guard let today = calendar.date(from: components) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// Submits the next refresh request, replacing any already pending.
    ///
    /// Called whenever the app goes to the background and at the start of each refresh,
    /// so there is always exactly one request in flight. `submit` throws on the simulator
    /// and when Background App Refresh is off for the app; neither is worth more than a log
    /// line, since the foreground path still re-arms everything.
    static func scheduleBackgroundRefresh(now: Date = Date(), calendar: Calendar = .current) {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
        request.earliestBeginDate = nextBackgroundRefreshDate(now: now, calendar: calendar)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.log(
                "Could not schedule the notification refresh: \(error.localizedDescription)",
                label: "Notifications",
                level: .debug
            )
        }
    }
}
