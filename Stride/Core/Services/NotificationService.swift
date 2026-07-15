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

    /// Called on MainActor when the user taps a SYNCED_RUN notification.
    /// The argument is the `RunWorkout.id.uuidString` embedded in the notification payload.
    var onSyncedRunTapped: ((String) -> Void)? {
        didSet {
            replayBufferedSyncedRunTapIfNeeded()
        }
    }

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
            return settings.authorizationStatus == .authorized
        }
    }

    // MARK: Scheduling

    /// Schedules an 8 AM morning reminder on the day of a planned workout.
    func scheduleMorningReminder(for workout: ScheduledWorkout) async throws {
        guard workout.workoutType != .rest else { return }

        let content = UNMutableNotificationContent()
        content.title = "Workout today"
        content.body = "You have a \(workout.workoutType.displayName) workout scheduled today. Lace up!"
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
        content.title = "Run Synced"
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
        content.title = "Runs Synced"
        content.body = "\(count) runs were imported from Apple Health."
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
        content.title = "Time to run!"
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
        content.title = "Workout today"
        content.body = "You have a \(workout.workoutType.displayName) workout scheduled today. Lace up!"
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

    // MARK: Private

    private func syncedRunBody(for workout: RunWorkout, unit: UnitPreference) -> String {
        let distance = workout.distanceMeters.distanceString(unit: unit)
        let pace = workout.averagePaceSecondsPerKm.paceString(unit: unit)
        return "\(workout.workoutType.displayName) · \(distance) · \(pace)"
    }

    private func storeReviewSnapshot(for workout: RunWorkout) {
        let snapshot = SyncedRunReviewSnapshot(workout: workout)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.reviewSnapshotKey(workout.id.uuidString))
    }

    private nonisolated static func reviewSnapshotKey(_ idString: String) -> String {
        "syncedRunReviewSnapshot.\(idString)"
    }

    private func reminderBody(for workout: ScheduledWorkout, minutesBefore: Int) -> String {
        let type = workout.workoutType.displayName
        if minutesBefore == 0 {
            return "Your \(type) workout starts now. Lace up!"
        }
        return "Your \(type) workout is in \(minutesBefore) min. Get ready!"
    }

    private func replayBufferedSyncedRunTapIfNeeded() {
        guard let workoutID = bufferedSyncedRunTapID, let onSyncedRunTapped else { return }
        bufferedSyncedRunTapID = nil
        onSyncedRunTapped(workoutID)
    }

    private func handleSyncedRunTap(workoutID: String) {
        UserDefaults.standard.set(workoutID, forKey: "pendingReviewWorkoutID")
        guard let onSyncedRunTapped else {
            bufferedSyncedRunTapID = workoutID
            return
        }
        onSyncedRunTapped(workoutID)
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
        let workoutTypeRaw: String
        let workoutLocationRaw: String
        let notes: String?
        let healthKitWorkoutID: String?
        let splitsData: Data?
        let routeData: Data?
        let weatherData: Data?

        init(workout: RunWorkout) {
            self.id = workout.id
            self.date = workout.date
            self.distanceMeters = workout.distanceMeters
            self.durationSeconds = workout.durationSeconds
            self.averagePaceSecondsPerKm = workout.averagePaceSecondsPerKm
            self.averageHeartRate = workout.averageHeartRate
            self.maxHeartRate = workout.maxHeartRate
            self.elevationGainMeters = workout.elevationGainMeters
            self.workoutTypeRaw = workout.workoutTypeRaw
            self.workoutLocationRaw = workout.workoutLocationRaw
            self.notes = workout.notes
            self.healthKitWorkoutID = workout.healthKitWorkoutID
            self.splitsData = workout.splitsData
            self.routeData = workout.routeData
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
            workout.notes = notes
            workout.healthKitWorkoutID = healthKitWorkoutID
            workout.splitsData = splitsData
            workout.routeData = routeData
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
