import Foundation
import UserNotifications

// MARK: - NotificationService

@MainActor
final class NotificationService {

    static let shared = NotificationService()
    private init() {}

    private let center = UNUserNotificationCenter.current()

    // Notification category identifiers
    private enum Category {
        static let workoutReminder = "WORKOUT_REMINDER"
        static let syncedRun       = "SYNCED_RUN"
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
        for week in plan.weeks {
            for workout in week.workouts where !workout.isCompleted {
                try? await scheduleReminder(for: workout, minutesBefore: minutesBefore)
            }
        }
    }

    /// Fires an immediate local notification when a run is automatically synced from Apple Health.
    /// Silently skipped if the user has not granted notification permission.
    func notifyNewRunSynced(_ workout: RunWorkout) async throws {
        guard await isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Run Synced"
        content.body  = syncedRunBody(for: workout)
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

    private func syncedRunBody(for workout: RunWorkout) -> String {
        let km = String(format: "%.1f", workout.distanceMeters / 1_000)
        let pace = workout.averagePaceSecondsPerKm.paceString
        return "\(workout.workoutType.displayName) · \(km) km · \(pace)"
    }

    private func reminderBody(for workout: ScheduledWorkout, minutesBefore: Int) -> String {
        let type = workout.workoutType.displayName
        if minutesBefore == 0 {
            return "Your \(type) workout starts now. Lace up!"
        }
        return "Your \(type) workout is in \(minutesBefore) min. Get ready!"
    }
}
