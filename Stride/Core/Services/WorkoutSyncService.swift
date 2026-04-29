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

    private func attachWeather(to workout: RunWorkout, coordinate: Coordinate) async {
        guard let summary = await weatherService.fetchWeather(at: coordinate, date: workout.date) else { return }
        workout.weather = summary
        try? context.save()
    }
}
