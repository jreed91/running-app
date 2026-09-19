import Foundation
import SwiftData
import UserNotifications

// MARK: - NotificationService

@MainActor
final class NotificationService: NSObject {

    static let shared = NotificationService()
    private override init() {
        super.init()
        installAsDelegate()
    }

    private let center = UNUserNotificationCenter.current()

    // Guards against concurrent scheduleMorningReminders calls racing through the
    // UNUserNotificationCenter.add path and delivering two notifications before iOS
    // can replace the first pending one with the second (same-ID) request.
    private var isBulkScheduling = false

    // A plan whose reschedule request arrived while another bulk pass was in
    // flight. Replayed by the in-flight caller so the newest request wins
    // instead of being silently dropped, which left stale reminders (M3).
    private var pendingBulkPlan: TrainingPlan?

    /// Taps on a SYNCED_RUN notification, as a stream of the `RunWorkout.id.uuidString`
    /// carried in the payload.
    ///
    /// This was a stored `onSyncedRunTapped` closure, and this service is a process-wide
    /// singleton — it is the `UNUserNotificationCenter` delegate — so that closure belonged
    /// to whichever `AppContainer` was built last, which in a test run or a preview is not
    /// the one on screen. The container worked around it by refusing to register when it
    /// was in-memory; the shape was the problem (D4). A stream has no single slot to
    /// clobber: every listener gets every tap, a tap that lands before anyone is listening
    /// is held and replayed to the next one (the cold-launch case), and a listener's
    /// registration ends with its task rather than being overwritten by the next container.
    var syncedRunTaps: AsyncStream<String> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            syncedRunTapListeners[id] = continuation
            if let buffered = bufferedSyncedRunTapID {
                bufferedSyncedRunTapID = nil
                continuation.yield(buffered)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.syncedRunTapListeners[id] = nil }
            }
        }
    }

    private var syncedRunTapListeners: [UUID: AsyncStream<String>.Continuation] = [:]

    /// A tap that arrived with nothing listening yet, replayed to the first listener.
    private var bufferedSyncedRunTapID: String?

    /// Taps on a HEAT_ADVISORY notification, as a stream of the workout's `id.uuidString`.
    ///
    /// Same shape as `syncedRunTaps`, and for the same reason (D4): this service is a
    /// process-wide singleton, so a stored callback would belong to whichever
    /// `AppContainer` was built last. The banner says "tap to move it", and a tap that
    /// merely foregrounds the app onto whatever tab was open last does not honour that.
    var heatAdvisoryTaps: AsyncStream<String> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            heatAdvisoryTapListeners[id] = continuation
            if let buffered = bufferedHeatAdvisoryTapID {
                bufferedHeatAdvisoryTapID = nil
                continuation.yield(buffered)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.heatAdvisoryTapListeners[id] = nil }
            }
        }
    }

    private var heatAdvisoryTapListeners: [UUID: AsyncStream<String>.Continuation] = [:]

    /// A heat-advisory tap that woke the app before any listener existed.
    private var bufferedHeatAdvisoryTapID: String?

    /// Taps on a training nudge — the streak prod, the missed-workout push, the weekly
    /// recap — as a stream of the kind that was tapped.
    ///
    /// Same shape and same reason as `heatAdvisoryTaps` (D4). Each of the three points at
    /// a different surface: the recovery card and the streak both live on the dashboard,
    /// the recap belongs on Progress, and a tap that merely foregrounds the app onto
    /// whichever tab was open last lands on none of them.
    var trainingNudgeTaps: AsyncStream<TrainingNudgeKind> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            trainingNudgeTapListeners[id] = continuation
            if let buffered = bufferedTrainingNudgeKind {
                bufferedTrainingNudgeKind = nil
                continuation.yield(buffered)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.trainingNudgeTapListeners[id] = nil }
            }
        }
    }

    private var trainingNudgeTapListeners: [UUID: AsyncStream<TrainingNudgeKind>.Continuation] = [:]

    /// A training-nudge tap that woke the app before any listener existed.
    private var bufferedTrainingNudgeKind: TrainingNudgeKind?

    func installAsDelegate() {
        center.delegate = self
    }

    // Notification category identifiers
    private enum Category {
        static let workoutReminder = "WORKOUT_REMINDER"
        static let syncedRun       = "SYNCED_RUN"
        static let heatAdvisory    = "HEAT_ADVISORY"
        static let trainingNudge   = "TRAINING_NUDGE"
    }

    /// `userInfo` key carrying a ``TrainingNudgeKind``'s raw value on a nudge.
    ///
    /// `nonisolated` because the tap handler in the delegate extension is, like the
    /// review-snapshot keys below.
    private nonisolated static let trainingNudgeKindKey = "trainingNudgeKind"

    // Notification identifier helpers
    private enum NotificationID {
        static func morning(_ workout: ScheduledWorkout) -> String {
            "morning-\(workout.id.uuidString)"
        }

        /// Keyed by session **and tier**, matching `HeatAdvisoryStore`'s dismissal key: a
        /// forecast that worsens overnight is a different warning about a different day
        /// and gets its own request rather than being swallowed as a duplicate.
        static func heatAdvisory(_ advisory: HeatAdvisory) -> String {
            "\(heatAdvisoryPrefix)\(advisory.workoutID.uuidString).\(advisory.tier.rawValue)"
        }

        static let heatAdvisoryPrefix = "heat-advisory-"

        /// One pending request per kind, replaced rather than accumulated: the streak
        /// nudge is always about tonight and the recap always about this week, so a
        /// second one is never a different message — it is the same message recomputed.
        static func trainingNudge(_ kind: TrainingNudgeKind) -> String {
            "\(trainingNudgePrefix)\(kind.rawValue)"
        }

        static let trainingNudgePrefix = "training-nudge-"
    }

    // MARK: Authorization

    func requestAuthorization() async throws {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    var isAuthorized: Bool {
        get async {
            let settings = await center.notificationSettings()
            // Provisional (quiet) and ephemeral (App Clip) grants can still deliver
            // notifications, so treat them as authorized rather than blocking reminders.
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return true
            default: return false
            }
        }
    }

    // MARK: Scheduling

    /// Schedules an 8 AM morning reminder on the day of a planned workout.
    func scheduleMorningReminder(for workout: ScheduledWorkout) async throws {
        guard workout.workoutType != .rest else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Workout today", comment: "Morning reminder notification title")
        content.body = String(
            localized: "You have a \(workout.workoutType.localizedName) workout scheduled today. Lace up!",
            comment: "Morning reminder notification body"
        )
        content.sound = .default
        content.categoryIdentifier = Category.workoutReminder

        guard
            let fireDate = Self.morningFireDate(for: workout),
            fireDate > Date()
        else { return }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: NotificationID.morning(workout),
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    /// Schedules 8 AM morning reminders for the soonest future non-rest workouts
    /// in a plan (capped — see `maxScheduledMorningReminders`).
    func scheduleMorningReminders(for plan: TrainingPlan) async {
        // Claim the flag before the first suspension point: checking it and then
        // awaiting isAuthorized before setting it left a window where concurrent
        // calls interleaved cancels and adds (M3). The losing call is queued and
        // replayed by the in-flight pass so its request is not silently dropped.
        if isBulkScheduling {
            pendingBulkPlan = plan
            return
        }
        isBulkScheduling = true
        defer {
            isBulkScheduling = false
            pendingBulkPlan = nil
        }

        var nextPlan: TrainingPlan? = plan
        while let plan = nextPlan {
            guard await isAuthorized else { return }

            await cancelAllMorningReminders()
            for workout in Self.morningReminderCandidates(for: plan) {
                try? await scheduleMorningReminder(for: workout)
            }

            nextPlan = pendingBulkPlan
            pendingBulkPlan = nil
        }
    }

    /// iOS keeps at most 64 pending local notifications per app and silently
    /// discards the rest, so a 16–18-week plan (80–100 reminders) lost its tail
    /// (M7). Cap what we schedule to the soonest workouts — the cap slides
    /// forward every reschedule — and leave headroom for synced-run banners.
    static let maxScheduledMorningReminders = 56

    /// The workouts in `plan` that should get a morning reminder: not completed,
    /// not rest days, fire date still in the future — soonest first, capped at
    /// `limit`. Pure so the cap and filtering are unit-testable.
    static func morningReminderCandidates(
        for plan: TrainingPlan,
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = maxScheduledMorningReminders
    ) -> [ScheduledWorkout] {
        let upcoming = (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter { workout in
                guard !workout.isCompleted, workout.workoutType != .rest,
                      let fireDate = morningFireDate(for: workout, calendar: calendar)
                else { return false }
                return fireDate > now
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }
        return Array(upcoming.prefix(limit))
    }

    /// 8 AM on the workout's scheduled day.
    static func morningFireDate(
        for workout: ScheduledWorkout,
        calendar: Calendar = .current
    ) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: workout.scheduledDate)
        components.hour = 8
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)
    }

    func cancelMorningReminder(for workout: ScheduledWorkout) {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.morning(workout)])
    }

    func cancelAllMorningReminders() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.filter { $0.identifier.hasPrefix("morning-") }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Fires an immediate local notification when a run is automatically synced from Apple Health.
    /// Silently skipped if the user has not granted notification permission.
    func notifyNewRunSynced(
        _ workout: RunWorkout,
        unit: UnitPreference = .metric,
        opensReviewOnTap: Bool = true
    ) async throws {
        guard await isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Run Synced", comment: "Notification title when one run is imported from Apple Health")
        content.body  = syncedRunBody(for: workout, unit: unit)
        content.sound = .default
        content.categoryIdentifier = Category.syncedRun
        content.userInfo = [
            "workoutID": workout.id.uuidString,
            "opensReviewOnTap": opensReviewOnTap
        ]
        if opensReviewOnTap {
            storeReviewSnapshot(for: workout)
        }
        // nil trigger → fires immediately
        let request = UNNotificationRequest(
            identifier: "synced-run-\(workout.id.uuidString)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    /// Fires a single summary notification for a multi-run import batch —
    /// a fresh-install recovery can import dozens of runs at once, and one
    /// banner per run is a notification storm (M5). Not tappable-to-review:
    /// there is no single run to open.
    func notifyRunBatchSynced(count: Int) async throws {
        guard count > 0, await isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Runs Synced", comment: "Notification title when several runs are imported from Apple Health")
        content.body = String(
            localized: "\(count) runs were imported from Apple Health.",
            comment: "Notification body when several runs are imported"
        )
        content.sound = .default
        content.categoryIdentifier = Category.syncedRun
        content.userInfo = ["opensReviewOnTap": false]
        let request = UNNotificationRequest(
            identifier: "synced-run-batch-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    // MARK: Heat advisories

    /// When a heat advisory should reach the runner.
    enum HeatAdvisoryDelivery: Equatable, Sendable {
        /// Still ahead of the evening slot — schedule it.
        case scheduled(Date)
        /// The evening before, but past the slot: the app happened to be open late, and
        /// the warning is still actionable tonight. Deliver it now rather than dropping it.
        case immediate
        /// The session's day has already begun. The dashboard card is the surface for
        /// that; a banner on the morning of is a warning the runner can no longer plan
        /// around, which is the thing this feature exists to avoid.
        case skip
    }

    /// The evening slot: 18:00 the day before the session.
    ///
    /// Late enough that the forecast has settled and the runner is off their feet, early
    /// enough to still change tomorrow — set an alarm an hour earlier, book the treadmill,
    /// swap the session with an easy day. Pure so both branches are unit-testable.
    static func heatAdvisoryDelivery(
        for scheduledDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HeatAdvisoryDelivery {
        let sessionDay = calendar.startOfDay(for: scheduledDate)
        guard now < sessionDay else { return .skip }

        var components = calendar.dateComponents([.year, .month, .day], from: sessionDay.addingTimeInterval(-86_400))
        components.hour = heatAdvisoryHour
        components.minute = 0
        components.second = 0

        guard let slot = calendar.date(from: components) else { return .skip }
        return now < slot ? .scheduled(slot) : .immediate
    }

    static let heatAdvisoryHour = 18

    /// Warns the runner the evening before that tomorrow's session is going to be hot.
    ///
    /// Replaces any pending advisory first, so a forecast that changed during the day
    /// cannot leave last night's number queued alongside tonight's.
    func scheduleHeatAdvisory(
        _ advisory: HeatAdvisory,
        unit: UnitPreference = .metric,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async {
        guard await isAuthorized else { return }

        let delivery = Self.heatAdvisoryDelivery(for: advisory.scheduledDate, now: now, calendar: calendar)
        guard delivery != .skip else { return }

        await cancelHeatAdvisories()

        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "Tomorrow looks hot",
            comment: "Notification title warning that tomorrow's session falls in the heat"
        )
        content.body = Self.heatAdvisoryBody(advisory, unit: unit)
        content.sound = .default
        content.categoryIdentifier = Category.heatAdvisory
        content.userInfo = ["heatAdvisoryWorkoutID": advisory.workoutID.uuidString]

        let trigger: UNCalendarNotificationTrigger?
        switch delivery {
        case let .scheduled(fireDate):
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        case .immediate, .skip:
            trigger = nil
        }

        let request = UNNotificationRequest(
            identifier: NotificationID.heatAdvisory(advisory),
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    /// Removes every pending heat advisory. Called before scheduling a new one, when the
    /// setting is switched off, and when the plan stops having a session to warn about.
    func cancelHeatAdvisories() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .filter { $0.identifier.hasPrefix(NotificationID.heatAdvisoryPrefix) }
            .map(\.identifier)
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// The banner's copy: what it will be, and the one thing to do about it.
    ///
    /// Internal rather than private so `HeatAdvisoryTests` can assert the conditions
    /// reach the body — a warning that says "it'll be hot" and no number is one the runner
    /// has to open the app to act on, which defeats sending it the night before.
    static func heatAdvisoryBody(_ advisory: HeatAdvisory, unit: UnitPreference) -> String {
        let conditions = String(
            localized: """
                \(advisory.workoutType.localizedName) at \
                \(advisory.conditions.feelsLikeString(unit: unit)), \
                dew point \(advisory.conditions.dewPointString(unit: unit)).
                """,
            comment: "First sentence of the heat advisory notification: the session and the conditions"
        )

        if let cooler = advisory.cooler {
            let time = cooler.start.formatted(.dateTime.hour().minute())
            return conditions + " " + String(
                localized: "It's \(cooler.conditions.feelsLikeString(unit: unit)) at \(time) — tap to move it or ease the targets.",
                comment: "Second sentence of the heat advisory notification when a cooler hour exists"
            )
        }
        return conditions + " " + String(
            localized: "Tap to ease tomorrow's targets before you head out.",
            comment: "Second sentence of the heat advisory notification"
        )
    }

    // MARK: Training nudges (A9)

    /// Arms tonight's evening nudge — the streak prod or the missed-workout push,
    /// whichever `TrainingNudgePolicy` picked.
    ///
    /// Safe to call on every foreground, which is how it is called: the pending request
    /// carries a stable identifier so re-arming replaces rather than duplicates, and an
    /// immediate delivery is gated on ``TrainingNudgeLog`` so a runner who opens the app
    /// three times this evening still gets one banner.
    ///
    /// Cancels the *other* evening kind as it goes. The slot holds one push, and a plan
    /// that was behind this morning and has since been shifted forward should not still
    /// have a banner queued about it.
    func scheduleEveningNudge(
        _ nudge: TrainingNudge,
        now: Date = Date(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) async {
        guard await isAuthorized else { return }

        let delivery = TrainingNudgePolicy.eveningDelivery(now: now, calendar: calendar)
        guard delivery != .skip else { return }

        let other: TrainingNudgeKind = nudge.kind == .streak ? .missedWorkouts : .streak
        cancelTrainingNudge(other)

        let content = UNMutableNotificationContent()
        content.title = Self.trainingNudgeTitle(nudge.kind)
        switch nudge {
        case let .streak(streak):         content.body = Self.streakNudgeBody(streak)
        case let .missedWorkouts(info):   content.body = Self.missedWorkoutNudgeBody(info)
        }

        await deliver(
            content,
            as: nudge.kind,
            delivery: delivery,
            now: now,
            calendar: calendar,
            defaults: defaults
        )
    }

    /// Arms Sunday evening's recap of the week just finished.
    func scheduleWeeklyRecap(
        _ recap: WeeklyRecap,
        unit: UnitPreference = .metric,
        now: Date = Date(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) async {
        guard await isAuthorized else { return }

        let delivery = TrainingNudgePolicy.weeklyRecapDelivery(now: now, calendar: calendar)
        guard delivery != .skip else { return }

        let content = UNMutableNotificationContent()
        content.title = Self.trainingNudgeTitle(.weeklyRecap)
        content.body = Self.weeklyRecapBody(recap, unit: unit)

        await deliver(
            content,
            as: .weeklyRecap,
            delivery: delivery,
            now: now,
            calendar: calendar,
            defaults: defaults
        )
    }

    /// Adds the request for `kind`, either at its slot or right now, and records the
    /// period as handled either way. Shared by the three nudges so the log is written in
    /// one place rather than at each call site.
    private func deliver(
        _ content: UNMutableNotificationContent,
        as kind: TrainingNudgeKind,
        delivery: TrainingNudgeDelivery,
        now: Date,
        calendar: Calendar,
        defaults: UserDefaults
    ) async {
        let period = TrainingNudgePolicy.period(for: kind, now: now, calendar: calendar)

        let trigger: UNCalendarNotificationTrigger?
        switch delivery {
        case let .scheduled(fireDate):
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        case .immediate:
            // The slot has passed, so anything already queued for it has fired. Without
            // this guard, the second foreground of the evening repeats the banner.
            guard !TrainingNudgeLog.hasHandled(kind, period: period, in: defaults) else { return }
            trigger = nil
        case .skip:
            return
        }

        content.sound = .default
        content.categoryIdentifier = Category.trainingNudge
        content.userInfo = [Self.trainingNudgeKindKey: kind.rawValue]

        let request = UNNotificationRequest(
            identifier: NotificationID.trainingNudge(kind),
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
            TrainingNudgeLog.markHandled(kind, period: period, in: defaults)
        } catch {
            AppLogger.log(
                "Could not arm the \(kind.rawValue) nudge: \(error.localizedDescription)",
                label: "Notifications",
                level: .error
            )
        }
    }

    /// Drops the pending request for `kind`. Used when the reason for it goes away —
    /// the runner logs today's run, or shifts the plan forward from the recovery card.
    func cancelTrainingNudge(_ kind: TrainingNudgeKind) {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.trainingNudge(kind)])
    }

    /// Drops every pending nudge, and optionally the delivery marks with it.
    ///
    /// `includingLog` is for switching the setting off: leaving today's marks behind
    /// would make switching it straight back on silent until tomorrow.
    func cancelTrainingNudges(includingLog: Bool = false, defaults: UserDefaults = .standard) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .filter { $0.identifier.hasPrefix(NotificationID.trainingNudgePrefix) }
            .map(\.identifier)
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        if includingLog {
            TrainingNudgeLog.clearAll(in: defaults)
        }
    }

    /// The banner's first line. One spelling per kind, shared by the real schedule and
    /// the QA trigger — two copies of a localized literal is two entries in
    /// `Localizable.xcstrings` that drift the first time one of them is reworded.
    static func trainingNudgeTitle(_ kind: TrainingNudgeKind) -> String {
        switch kind {
        case .streak:
            return String(
                localized: "Your streak is on the line",
                comment: "Notification title when a run streak will end at midnight"
            )
        case .missedWorkouts:
            return String(
                localized: "Pick the plan back up",
                comment: "Notification title when several planned sessions have been missed"
            )
        case .weeklyRecap:
            return String(
                localized: "Your week in running",
                comment: "Notification title for the Sunday-evening weekly recap"
            )
        }
    }

    /// "Your 12-day streak ends at midnight" — the number, because the number is the
    /// whole reason the message works, and the smallest run that saves it.
    ///
    /// Internal rather than private so `TrainingNudgePolicyTests` can assert the streak
    /// length reaches the body: a nudge that says "your streak is at risk" and no number is one
    /// the runner has to open the app to size up, which is what the banner is for.
    static func streakNudgeBody(_ nudge: StreakNudge) -> String {
        String(
            localized: """
                You haven't logged a run today, so your \(nudge.days)-day streak ends at \
                midnight. Twenty easy minutes keeps it alive.
                """,
            comment: "Notification body nudging the runner to protect a run streak that ends tonight"
        )
    }

    /// "Four sessions have gone by" — the count and how far behind the plan now is, so
    /// the runner knows what tapping through is going to offer to do.
    static func missedWorkoutNudgeBody(_ info: MissedWorkoutInfo) -> String {
        let missed = String(
            localized: "\(info.count) planned sessions have gone by unlogged.",
            comment: "First sentence of the missed-workout notification: how many sessions were missed"
        )
        guard info.daysToShift > 0 else {
            return missed + " " + String(
                localized: "Tap to shift the rest of the plan forward and pick it back up.",
                comment: "Second sentence of the missed-workout notification"
            )
        }
        return missed + " " + String(
            localized: "Tap to shift the rest of the plan \(info.daysToShift) days forward and pick it back up.",
            comment: "Second sentence of the missed-workout notification, naming the shift in days"
        )
    }

    /// The week in two sentences: what was run, and how that sat against the goal.
    static func weeklyRecapBody(_ recap: WeeklyRecap, unit: UnitPreference) -> String {
        let total = recap.totalMeters.distanceString(unit: unit)
        let longest = recap.longestRunMeters.distanceString(unit: unit)

        // Spelled out rather than interpolated because `String(localized:)` extracts one
        // key per call and "1 runs" is what a single interpolation produces.
        let totals = recap.runCount == 1
            ? String(
                localized: "1 run, \(total).",
                comment: "First sentence of the weekly recap when exactly one run was logged"
            )
            : String(
                localized: "\(recap.runCount) runs, \(total) — longest \(longest).",
                comment: "First sentence of the weekly recap: run count, weekly distance, longest run"
            )

        guard recap.hasGoal else { return totals }
        let goal = recap.goalMeters.distanceString(unit: unit)

        if recap.isGoalMet {
            return totals + " " + String(
                localized: "That clears your \(goal) weekly goal.",
                comment: "Second sentence of the weekly recap when the weekly goal was met"
            )
        }
        return totals + " " + String(
            localized: "\(recap.remainingMeters.distanceString(unit: unit)) short of your \(goal) goal.",
            comment: "Second sentence of the weekly recap when the weekly goal was missed"
        )
    }

    // MARK: Cancellation

    /// Cancels every pending reminder belonging to `plan` — used when a plan is
    /// deleted so its morning reminders don't keep firing for workouts that no
    /// longer exist. Removes both the standard (`<uuid>`) and morning
    /// (`morning-<uuid>`) identifiers for each of the plan's workouts.
    func cancelReminders(for plan: TrainingPlan) {
        let workouts = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }
        let ids = workouts.flatMap { [$0.id.uuidString, NotificationID.morning($0)] }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: Test helpers

    /// Triggers all local notification types immediately for TestFlight QA.
    /// Safe to call in other environments, but intended for internal builds only.
    func triggerAllTestNotifications(in context: ModelContext? = nil) async throws {
        try await triggerWorkoutReminderTestNotification()
        try await triggerMorningReminderTestNotification()
        try await triggerSyncedRunTestNotification(in: context)
        try await triggerTrainingNudgeTestNotifications()
    }

    /// Fires one of each A9 nudge immediately, with sample numbers, so the copy can be
    /// read on a real Lock Screen.
    ///
    /// Deliberately bypasses `scheduleEveningNudge` — that path is gated on the evening
    /// slot and the delivery log, and a QA trigger that only works between 18:00 and
    /// 21:00, once, is not one anybody will use.
    func triggerTrainingNudgeTestNotifications(unit: UnitPreference = .metric) async throws {
        guard await isAuthorized else { return }

        let samples: [(kind: TrainingNudgeKind, body: String)] = [
            (.streak, Self.streakNudgeBody(StreakNudge(days: 12))),
            (
                .missedWorkouts,
                Self.missedWorkoutNudgeBody(
                    MissedWorkoutInfo(count: 3, firstMissedDate: Date(), daysToShift: 5)
                )
            ),
            (
                .weeklyRecap,
                Self.weeklyRecapBody(
                    WeeklyRecap(
                        weekStart: Date(),
                        runCount: 4,
                        totalMeters: 32_400,
                        longestRunMeters: 16_100,
                        goalMeters: 30_000
                    ),
                    unit: unit
                )
            )
        ]

        for (kind, body) in samples {
            let content = UNMutableNotificationContent()
            content.title = Self.trainingNudgeTitle(kind)
            content.body = body
            content.sound = .default
            content.categoryIdentifier = Category.trainingNudge
            content.userInfo = [Self.trainingNudgeKindKey: kind.rawValue]
            let request = UNNotificationRequest(
                identifier: "test-training-nudge-\(kind.rawValue)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try await center.add(request)
        }
    }

    func triggerWorkoutReminderTestNotification() async throws {
        guard await isAuthorized else { return }
        let workout = ScheduledWorkout(
            scheduledDate: Date(),
            workoutType: .tempo
        )
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to run!", comment: "Notification title at the scheduled workout time")
        content.body = reminderBody(for: workout, minutesBefore: 0)
        content.sound = .default
        content.categoryIdentifier = Category.workoutReminder
        let request = UNNotificationRequest(
            identifier: "test-workout-reminder-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    func triggerMorningReminderTestNotification() async throws {
        guard await isAuthorized else { return }
        let workout = ScheduledWorkout(
            scheduledDate: Date(),
            workoutType: .easy
        )
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Workout today", comment: "Morning reminder notification title")
        content.body = String(
            localized: "You have a \(workout.workoutType.localizedName) workout scheduled today. Lace up!",
            comment: "Morning reminder notification body"
        )
        content.sound = .default
        content.categoryIdentifier = Category.workoutReminder
        let request = UNNotificationRequest(
            identifier: "test-morning-reminder-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    func triggerSyncedRunTestNotification(unit: UnitPreference = .metric, in context: ModelContext? = nil) async throws {
        // Build a transient sample run WITHOUT inserting it into the store (M39): the QA
        // notification must never pollute real stats or sync a fake run to CloudKit. The
        // tap-to-review flow still works — `notifyNewRunSynced` stores a review snapshot
        // that `AppContainer` surfaces from the snapshot fallback if the user taps.
        let workout = RunWorkout(
            date: Date(),
            distanceMeters: 5_000,
            durationSeconds: 1_500,
            workoutType: .easy
        )
        try await notifyNewRunSynced(workout, unit: unit, opensReviewOnTap: true)
    }

    func workoutFromReviewSnapshot(idString: String) -> RunWorkout? {
        guard
            let data = UserDefaults.standard.data(forKey: Self.reviewSnapshotKey(idString)),
            let snapshot = try? JSONDecoder().decode(SyncedRunReviewSnapshot.self, from: data),
            let workout = snapshot.workout
        else { return nil }
        return workout
    }

    func removeReviewSnapshot(idString: String) {
        UserDefaults.standard.removeObject(forKey: Self.reviewSnapshotKey(idString))
    }

    /// Removes persisted review snapshots for runs already present in the store,
    /// so full run copies don't accumulate in the defaults plist (S3). A snapshot
    /// is only a fallback for a run that hasn't imported yet; once the real row
    /// exists the snapshot is redundant. Injectable `defaults` for testability.
    nonisolated static func pruneReviewSnapshots(
        storedRunIDs: Set<UUID>,
        in defaults: UserDefaults = .standard
    ) {
        for key in reviewSnapshotKeys(in: defaults) {
            let idString = String(key.dropFirst(reviewSnapshotKeyPrefix.count))
            if let uuid = UUID(uuidString: idString), storedRunIDs.contains(uuid) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Drops the pending-review pointer **and every stored snapshot**, whether or
    /// not the run it describes is in the store.
    ///
    /// "Reset All Data" (N11) needs this: a snapshot is a full copy of a run, so a
    /// reset that only clears SwiftData leaves the next launch free to resurrect a
    /// run the user just deleted (`AppContainer.surfacePendingReviewWorkout`
    /// re-inserts from the snapshot when the row is missing — which, after a reset,
    /// it always is).
    nonisolated static func clearAllReviewState(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingReviewWorkoutIDKey)
        for key in reviewSnapshotKeys(in: defaults) {
            defaults.removeObject(forKey: key)
        }
    }

    private nonisolated static func reviewSnapshotKeys(in defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(reviewSnapshotKeyPrefix) }
    }

    // MARK: Private

    private func syncedRunBody(for workout: RunWorkout, unit: UnitPreference) -> String {
        let distance = workout.distanceMeters.distanceString(unit: unit)
        let pace = workout.averagePaceSecondsPerKm.paceString(unit: unit)
        return "\(workout.workoutType.localizedName) · \(distance) · \(pace)"
    }

    private func storeReviewSnapshot(for workout: RunWorkout) {
        let snapshot = SyncedRunReviewSnapshot(workout: workout)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.reviewSnapshotKey(workout.id.uuidString))
    }

    private nonisolated static let reviewSnapshotKeyPrefix = "syncedRunReviewSnapshot."

    /// Defaults key holding the id of a run synced outside the foreground, waiting
    /// to be surfaced for review. Shared so the writers (`handleSyncedRunTap`,
    /// `WorkoutSyncService`) and the readers/clearers (`AppContainer`, `StrideApp`,
    /// `clearAllReviewState`) can't drift apart on the spelling.
    nonisolated static let pendingReviewWorkoutIDKey = "pendingReviewWorkoutID"

    private nonisolated static func reviewSnapshotKey(_ idString: String) -> String {
        "\(reviewSnapshotKeyPrefix)\(idString)"
    }

    private func reminderBody(for workout: ScheduledWorkout, minutesBefore: Int) -> String {
        let type = workout.workoutType.localizedName
        if minutesBefore == 0 {
            return String(localized: "Your \(type) workout starts now. Lace up!", comment: "Reminder body, workout starting now")
        }
        return String(
            localized: "Your \(type) workout is in \(minutesBefore) min. Get ready!",
            comment: "Reminder body, workout starting soon"
        )
    }

    private func handleTrainingNudgeTap(kind: TrainingNudgeKind) {
        guard !trainingNudgeTapListeners.isEmpty else {
            bufferedTrainingNudgeKind = kind
            return
        }
        for listener in trainingNudgeTapListeners.values {
            listener.yield(kind)
        }
    }

    private func handleHeatAdvisoryTap(workoutID: String) {
        guard !heatAdvisoryTapListeners.isEmpty else {
            bufferedHeatAdvisoryTapID = workoutID
            return
        }
        for listener in heatAdvisoryTapListeners.values {
            listener.yield(workoutID)
        }
    }

    private func handleSyncedRunTap(workoutID: String) {
        UserDefaults.standard.set(workoutID, forKey: Self.pendingReviewWorkoutIDKey)
        guard !syncedRunTapListeners.isEmpty else {
            // Cold launch: the tap woke the app and no container is listening yet.
            bufferedSyncedRunTapID = workoutID
            return
        }
        for listener in syncedRunTapListeners.values {
            listener.yield(workoutID)
        }
    }

    private struct SyncedRunReviewSnapshot: Codable {
        let id: UUID
        let date: Date
        let distanceMeters: Double
        let durationSeconds: Double
        let averagePaceSecondsPerKm: Double
        let averageHeartRate: Double?
        let maxHeartRate: Double?
        let elevationGainMeters: Double?
        /// Optional so an older snapshot written before cadence was captured still decodes (A5).
        let averageCadenceStepsPerMinute: Double?
        let workoutTypeRaw: String
        let workoutLocationRaw: String
        let notes: String?
        let healthKitWorkoutID: String?
        let splitsData: Data?
        let weatherData: Data?
        // NOTE: the run's route (raw GPS coordinates) is deliberately NOT persisted
        // here — writing full location traces into the UserDefaults plist for every
        // synced run was a privacy leak (S3). The review sheet restored from a
        // snapshot shows the run without its map; the canonical import keeps the
        // route on the real stored row.

        init(workout: RunWorkout) {
            self.id = workout.id
            self.date = workout.date
            self.distanceMeters = workout.distanceMeters
            self.durationSeconds = workout.durationSeconds
            self.averagePaceSecondsPerKm = workout.averagePaceSecondsPerKm
            self.averageHeartRate = workout.averageHeartRate
            self.maxHeartRate = workout.maxHeartRate
            self.elevationGainMeters = workout.elevationGainMeters
            self.averageCadenceStepsPerMinute = workout.averageCadenceStepsPerMinute
            self.workoutTypeRaw = workout.workoutTypeRaw
            self.workoutLocationRaw = workout.workoutLocationRaw
            self.notes = workout.notes
            self.healthKitWorkoutID = workout.healthKitWorkoutID
            self.splitsData = workout.splitsData
            self.weatherData = workout.weatherData
        }

        var workout: RunWorkout? {
            let workout = RunWorkout(
                date: date,
                distanceMeters: distanceMeters,
                durationSeconds: durationSeconds,
                workoutType: WorkoutType(rawValue: workoutTypeRaw) ?? .easy,
                workoutLocation: WorkoutLocation(rawValue: workoutLocationRaw) ?? .outdoor
            )
            workout.id = id
            workout.averagePaceSecondsPerKm = averagePaceSecondsPerKm
            workout.averageHeartRate = averageHeartRate
            workout.maxHeartRate = maxHeartRate
            workout.elevationGainMeters = elevationGainMeters
            workout.averageCadenceStepsPerMinute = averageCadenceStepsPerMinute
            workout.notes = notes
            workout.healthKitWorkoutID = healthKitWorkoutID
            workout.splitsData = splitsData
            workout.weatherData = weatherData
            return workout
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    // Called when a notification arrives while the app is in the foreground.
    // Present the banner and keep the review modal tied to the user's tap.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    // Called when the user taps a delivered notification.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content

        if content.categoryIdentifier == Category.trainingNudge,
           let raw = content.userInfo[Self.trainingNudgeKindKey] as? String,
           let kind = TrainingNudgeKind(rawValue: raw) {
            Task { @MainActor in
                self.handleTrainingNudgeTap(kind: kind)
            }
            completionHandler()
            return
        }

        if content.categoryIdentifier == Category.heatAdvisory,
           let workoutID = content.userInfo["heatAdvisoryWorkoutID"] as? String {
            Task { @MainActor in
                self.handleHeatAdvisoryTap(workoutID: workoutID)
            }
            completionHandler()
            return
        }

        guard
            content.categoryIdentifier == Category.syncedRun,
            let workoutID = content.userInfo["workoutID"] as? String
        else {
            completionHandler()
            return
        }
        let opensReviewOnTap = Self.boolValue(content.userInfo["opensReviewOnTap"]) ?? true
        guard opensReviewOnTap else {
            completionHandler()
            return
        }

        Task { @MainActor in
            self.handleSyncedRunTap(workoutID: workoutID)
        }
        completionHandler()
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return Bool(string) }
        return nil
    }
}
