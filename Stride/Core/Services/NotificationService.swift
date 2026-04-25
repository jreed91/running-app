import Foundation
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

    /// Schedules a local notification for a planned workout.
    func scheduleReminder(for workout: ScheduledWorkout, minutesBefore: Int = 60) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Time to run!"
        content.body = reminderBody(for: workout, minutesBefore: minutesBefore)
        content.sound = .default
        content.categoryIdentifier = Category.workoutReminder

        let fireDate = workout.scheduledDate.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        guard fireDate > Date() else { return }  // past dates silently skipped

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: workout.id.uuidString,
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    /// Schedules reminders for all future workouts in a plan.
    func scheduleReminders(for plan: TrainingPlan, minutesBefore: Int = 60) async {
        for week in plan.weeks ?? [] {
            for workout in week.workouts ?? [] where !workout.isCompleted {
                try? await scheduleReminder(for: workout, minutesBefore: minutesBefore)
            }
        }
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
    func notifyNewRunSynced(_ workout: RunWorkout, unit: UnitPreference = .metric) async throws {
        guard await isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Run Synced"
        content.body  = syncedRunBody(for: workout, unit: unit)
        content.sound = .default
        content.categoryIdentifier = Category.syncedRun
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
}
