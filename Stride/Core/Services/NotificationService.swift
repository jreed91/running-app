import Foundation
import SwiftData
import UserNotifications

// MARK: - NotificationService

@MainActor
final class NotificationService: NSObject {

    static let shared = NotificationService()
    private override init() {
        super.init()
        center.delegate = self
    }

    private let center = UNUserNotificationCenter.current()

    /// Called on MainActor when the user taps a SYNCED_RUN notification.
    /// The argument is the `RunWorkout.id.uuidString` embedded in the notification payload.
    var onSyncedRunTapped: ((String) -> Void)?

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

    /// Standard pre-workout reminders are disabled.
    func scheduleReminder(for workout: ScheduledWorkout, minutesBefore: Int = 60) async throws {
    }

    /// Standard pre-workout reminders are disabled.
    func scheduleReminders(for plan: TrainingPlan, minutesBefore: Int = 60) async {
    }

    /// Schedules an 8 AM morning reminder on the day of a planned workout.
    func scheduleMorningReminder(for workout: ScheduledWorkout) async throws {
        guard workout.workoutType != .rest else { return }

        let content = UNMutableNotificationContent()
        content.title = "Workout today"
        content.body = "You have a \(workout.workoutType.displayName) workout scheduled today. Lace up!"
        content.sound = .default
        content.categoryIdentifier = Category.workoutReminder

        var components = Calendar.current.dateComponents([.year, .month, .day], from: workout.scheduledDate)
        components.hour = 8
        components.minute = 0
        components.second = 0

        guard
            let fireDate = Calendar.current.date(from: components),
            fireDate > Date()
        else { return }

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: NotificationID.morning(workout),
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    /// Schedules 8 AM morning reminders for all future non-rest workouts in a plan.
    func scheduleMorningReminders(for plan: TrainingPlan) async {
        for week in plan.weeks ?? [] {
            for workout in week.workouts ?? [] where !workout.isCompleted {
                try? await scheduleMorningReminder(for: workout)
            }
        }
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
        // nil trigger → fires immediately
        let request = UNNotificationRequest(
            identifier: "synced-run-\(workout.id.uuidString)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    // MARK: Cancellation

    func cancelReminder(for workout: ScheduledWorkout) {
        center.removePendingNotificationRequests(withIdentifiers: [workout.id.uuidString])
    }

    func cancelAllReminders() {
        center.removeAllPendingNotificationRequests()
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
        let workout = RunWorkout(
            date: Date(),
            distanceMeters: 5_000,
            durationSeconds: 1_500,
            workoutType: .easy
        )
        context?.insert(workout)
        try await notifyNewRunSynced(workout, unit: unit, opensReviewOnTap: context != nil)
    }

    // MARK: Private

    private func syncedRunBody(for workout: RunWorkout, unit: UnitPreference) -> String {
        let distance = workout.distanceMeters.distanceString(unit: unit)
        let pace = workout.averagePaceSecondsPerKm.paceString(unit: unit)
        return "\(workout.workoutType.displayName) · \(distance) · \(pace)"
    }

    private func reminderBody(for workout: ScheduledWorkout, minutesBefore: Int) -> String {
        let type = workout.workoutType.displayName
        if minutesBefore == 0 {
            return "Your \(type) workout starts now. Lace up!"
        }
        return "Your \(type) workout is in \(minutesBefore) min. Get ready!"
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    // Called when a notification arrives while the app is in the foreground.
    // Without this, immediate notifications (synced run, nil trigger) are silently dropped.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
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
        let opensReviewOnTap = content.userInfo["opensReviewOnTap"] as? Bool ?? true
        guard opensReviewOnTap else {
            completionHandler()
            return
        }

        Task { @MainActor in
            self.onSyncedRunTapped?(workoutID)
        }
        completionHandler()
    }
}
