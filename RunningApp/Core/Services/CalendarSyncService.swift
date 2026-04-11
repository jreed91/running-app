import EventKit
import UIKit

// MARK: - CalendarSyncService

/// Syncs scheduled training workouts to the user's Apple Calendar.
/// Each workout appears as a timed event inside a dedicated "Training Plan" calendar,
/// making it visible in Calendar, on Apple Watch, and via Siri suggestions.
@MainActor
final class CalendarSyncService {

    private let eventStore = EKEventStore()
    private static let calendarTitle = "Training Plan"
    private static let calendarColor = UIColor.systemGreen.cgColor

    // MARK: - Authorization

    /// Requests full calendar access. Returns `true` if granted.
    func requestAccess() async -> Bool {
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    // MARK: - Sync

    /// Creates (or updates) calendar events for every non-rest workout in the plan.
    /// Persists the assigned `EKEvent` identifier back onto each `ScheduledWorkout`.
    func syncPlan(_ plan: TrainingPlan) async {
        guard await requestAccess() else { return }
        guard let calendar = getOrCreateCalendar() else { return }

        for week in plan.weeks {
            for workout in week.workouts where workout.workoutType != .rest {
                addOrUpdateEvent(for: workout, in: calendar)
            }
        }
        try? eventStore.commit()
    }

    /// Removes all calendar events that were previously created for this plan's workouts.
    func removePlanEvents(for plan: TrainingPlan) async {
        guard await requestAccess() else { return }

        for week in plan.weeks {
            for workout in week.workouts {
                guard let eventID = workout.calendarEventID,
                      let event = eventStore.event(withIdentifier: eventID)
                else { continue }
                try? eventStore.remove(event, span: .thisEvent, commit: false)
                workout.calendarEventID = nil
            }
        }
        try? eventStore.commit()
    }

    // MARK: - Private helpers

    private func getOrCreateCalendar() -> EKCalendar? {
        if let existing = eventStore.calendars(for: .event)
            .first(where: { $0.title == Self.calendarTitle }) {
            return existing
        }

        let cal = EKCalendar(for: .event, eventStore: eventStore)
        cal.title = Self.calendarTitle
        cal.cgColor = Self.calendarColor

        guard let source = eventStore.defaultCalendarForNewEvents?.source
            ?? eventStore.sources.first(where: { $0.sourceType == .local })
            ?? eventStore.sources.first
        else { return nil }

        cal.source = source
        try? eventStore.saveCalendar(cal, commit: true)
        return cal
    }

    private func addOrUpdateEvent(for workout: ScheduledWorkout, in calendar: EKCalendar) {
        // Remove stale event from a previous sync
        if let oldID = workout.calendarEventID,
           let old = eventStore.event(withIdentifier: oldID) {
            try? eventStore.remove(old, span: .thisEvent, commit: false)
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = eventTitle(for: workout)
        event.notes = eventNotes(for: workout)
        event.calendar = calendar
        event.startDate = scheduledStartTime(for: workout)
        event.endDate = event.startDate.addingTimeInterval(estimatedDuration(for: workout))

        try? eventStore.save(event, span: .thisEvent, commit: false)
        workout.calendarEventID = event.eventIdentifier
    }

    // MARK: - Formatting helpers

    private func eventTitle(for workout: ScheduledWorkout) -> String {
        let type = workout.workoutType.displayName
        guard let distance = workout.targetDistanceMeters else { return "\(type) Run" }
        let km = distance / 1_000
        return String(format: "%@ Run – %.1f km", type, km)
    }

    private func eventNotes(for workout: ScheduledWorkout) -> String {
        var parts: [String] = []
        if let notes = workout.notes { parts.append(notes) }
        if let range = workout.targetPaceRange {
            parts.append("Target pace: \(formatPaceRange(range)) /km")
        }
        if !workout.intervals.isEmpty {
            let reps = workout.intervals.map { "\($0.repetitions)×\(Int($0.distanceMeters ?? 0))m" }
            parts.append("Intervals: \(reps.joined(separator: ", "))")
        }
        return parts.joined(separator: "\n")
    }

    /// Default workout start time is 7:00 am on the scheduled date.
    private func scheduledStartTime(for workout: ScheduledWorkout) -> Date {
        var components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: workout.scheduledDate
        )
        components.hour = 7
        components.minute = 0
        return Calendar.current.date(from: components) ?? workout.scheduledDate
    }

    /// Estimates workout duration from target distance × midpoint pace.
    private func estimatedDuration(for workout: ScheduledWorkout) -> TimeInterval {
        guard let distance = workout.targetDistanceMeters else { return 3_600 }
        let pacePerKm: Double
        if let range = workout.targetPaceRange {
            pacePerKm = (range.lowerBound + range.upperBound) / 2
        } else {
            pacePerKm = 360 // 6 min/km default
        }
        return (distance / 1_000) * pacePerKm
    }

    private func formatPaceRange(_ range: ClosedRange<Double>) -> String {
        "\(formatPace(range.lowerBound))–\(formatPace(range.upperBound))"
    }

    private func formatPace(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
