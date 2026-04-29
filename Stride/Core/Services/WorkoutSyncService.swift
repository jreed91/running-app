import Foundation
import SwiftData

// MARK: - WorkoutSyncService

/// Observes HealthKit for new running workouts and automatically imports them
/// into SwiftData, firing a local notification for each newly synced run.
///
/// Lifecycle:
///   1. Created by `AppContainer` at launch.
///   2. `startObserving()` is called once from `StrideApp` via `.task`.
///   3. iOS then wakes the app (even in the background) whenever new running
///      workouts arrive in HealthKit, triggering an import + notification.
@MainActor
final class WorkoutSyncService {

    // MARK: Dependencies

    private let healthKitRepository: HealthKitRepositoryProtocol
    private let notificationService: NotificationService
    private let weatherService: WeatherService
    private let context: ModelContext

    /// Called on MainActor after each batch of new workouts is imported and auto-linked.
    var onWorkoutsSynced: (([RunWorkout]) -> Void)?

    // MARK: Init

    init(
        healthKitRepository: HealthKitRepositoryProtocol,
        notificationService: NotificationService,
        weatherService: WeatherService,
        context: ModelContext
    ) {
        self.healthKitRepository = healthKitRepository
        self.notificationService = notificationService
        self.weatherService = weatherService
        self.context = context
    }

    // MARK: Public API

    /// Enables HealthKit background delivery and registers the observer query.
    /// No-op if HealthKit is unavailable or the user denies authorization.
    /// Safe to call multiple times — HealthKit background delivery is idempotent.
    func startObserving() async {
        guard healthKitRepository.isAvailable, healthKitRepository.isAuthorized else { return }
        do {
            try await healthKitRepository.enableBackgroundDelivery()
        } catch {
            return
        }

        // The handler is called on a HealthKit background queue, so we hop to
        // MainActor before touching SwiftData or NotificationService.
        healthKitRepository.registerObserverQuery { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleNewWorkoutsDetected()
            }
        }
    }

    // MARK: Private

    private func handleNewWorkoutsDetected() async {
        // Look back 7 days — the observer fires promptly after each new workout,
        // so a short window keeps the HealthKit query fast.
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()

        let existingIDs: Set<String>
        do {
            let stored = try context.fetch(FetchDescriptor<RunWorkout>())
            existingIDs = Set(stored.compactMap(\.healthKitWorkoutID))
        } catch {
            return
        }

        let newWorkouts: [RunWorkout]
        do {
            newWorkouts = try await healthKitRepository.fetchImportableWorkouts(
                from: cutoff,
                to: Date(),
                existingIDs: existingIDs
            )
        } catch {
            return
        }

        guard !newWorkouts.isEmpty else { return }

        for workout in newWorkouts {
            context.insert(workout)
        }
        linkToScheduledWorkouts(newWorkouts)
        do {
            try context.save()
        } catch {
            return
        }

        for workout in newWorkouts {
            if let coordinate = workout.routeCoordinates.first {
                await attachWeather(to: workout, coordinate: coordinate)
            }
        }

        autoLink(newWorkouts)

        let unit = AppSettings.syncedUnitPreference()
        for workout in newWorkouts {
            try? await notificationService.notifyNewRunSynced(workout, unit: unit)
        }

        if let first = newWorkouts.first {
            UserDefaults.standard.set(first.id.uuidString, forKey: "pendingReviewWorkoutID")
        }
        onWorkoutsSynced?(newWorkouts)
    }

    private func autoLink(_ workouts: [RunWorkout]) {
        let allScheduled = (try? context.fetch(FetchDescriptor<ScheduledWorkout>())) ?? []
        var dirty = false
        for workout in workouts {
            guard workout.scheduledWorkout == nil else { continue }
            if let match = allScheduled.first(where: {
                $0.completedWorkout == nil &&
                $0.workoutType != .rest &&
                Calendar.current.isDate($0.scheduledDate, inSameDayAs: workout.date)
            }) {
                match.completedWorkout = workout
                workout.scheduledWorkout = match
                match.isCompleted = true
                dirty = true
            }
        }
        if dirty { try? context.save() }
    }

    /// Matches each newly imported `RunWorkout` to an unlinked `ScheduledWorkout` on
    /// the same calendar day (or the day before, allowing for late completions).
    /// Uses workout type as a tiebreaker when multiple candidates share the same day.
    private func linkToScheduledWorkouts(_ runWorkouts: [RunWorkout]) {
        let toLink = runWorkouts.filter { $0.scheduledWorkout == nil }
        guard !toLink.isEmpty else { return }

        let descriptor = FetchDescriptor<ScheduledWorkout>(
            predicate: #Predicate { $0.isCompleted == false }
        )
        guard let allIncomplete = try? context.fetch(descriptor) else { return }
        // Keep only those not already linked to another run.
        var available = allIncomplete.filter { $0.completedWorkout == nil }

        let calendar = Calendar.current
        for run in toLink {
            let runDay = calendar.startOfDay(for: run.date)

            // Accept scheduled workouts from the same day or up to one day earlier
            // (covers users who complete a workout slightly past midnight, or a day late).
            let dayMatches = available.filter { scheduled in
                let scheduledDay = calendar.startOfDay(for: scheduled.scheduledDate)
                let diff = calendar.dateComponents([.day], from: scheduledDay, to: runDay).day ?? Int.max
                return diff >= 0 && diff <= 1
            }

            guard !dayMatches.isEmpty else { continue }

            // Prefer a type match, then fall back to the workout closest in scheduled time.
            let best = dayMatches.min { a, b in
                let aType = a.workoutType == run.workoutType
                let bType = b.workoutType == run.workoutType
                if aType != bType { return aType }
                return abs(a.scheduledDate.timeIntervalSince(run.date)) <
                       abs(b.scheduledDate.timeIntervalSince(run.date))
            }

            if let match = best {
                run.scheduledWorkout = match
                // Adopt the scheduled type so the completed run reflects the planned intent,
                // overriding the coarse type inferred from distance/pace alone.
                run.workoutType = match.workoutType
                match.completedWorkout = run
                match.isCompleted = true
                // Remove from available pool so it can't be matched twice.
                available.removeAll { $0.id == match.id }
            }
        }
    }

    private func attachWeather(to workout: RunWorkout, coordinate: Coordinate) async {
        guard let summary = await weatherService.fetchWeather(at: coordinate, date: workout.date) else { return }
        workout.weather = summary
        try? context.save()
    }
}
