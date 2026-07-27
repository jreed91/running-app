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

    func installAsDelegate() {
        center.delegate = self
    }

    // Notification category identifiers
    private enum Category {
        static let workoutReminder = "WORKOUT_REMINDER"
        static let syncedRun       = "SYNCED_RUN"
    }

    // Notification identifier helpers
    private enum NotificationID {
        static func morning(_ workout: ScheduledWorkout) -> String {
            "morning-\(workout.id.uuidString)"
        }
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
