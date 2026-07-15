import Foundation
import SwiftData

// MARK: - WorkoutSyncService

/// Observes HealthKit for new running workouts and automatically imports them
/// into SwiftData, firing a local notification for each newly synced run (or a
/// single summary notification for large recovery imports).
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
    private var isObserving = false
    private var isSyncing = false

    /// Source label of a sync trigger that arrived while another sync was in
    /// flight. The in-flight pass replays it when it finishes instead of
    /// dropping the trigger (M1). `private(set)` so tests can observe queueing.
    private(set) var pendingSyncSource: String?

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
        guard healthKitRepository.isAvailable else {
            AppLogger.log("HealthKit is unavailable; workout background sync not started.", label: "HealthKit", level: .warning)
            return
        }

        if !isObserving {
            // Claim the flag before the first suspension point: startObserving is
            // called concurrently (StrideApp.task, onboarding, the restore flow),
            // and a check-then-set separated by an await let two callers both see
            // "not observing" and register duplicate observer queries (M2).
            isObserving = true
            do {
                try await healthKitRepository.enableBackgroundDelivery()
            } catch {
                isObserving = false
                AppLogger.log(
                    "Failed to enable HealthKit background delivery: \(error.localizedDescription)",
                    label: "HealthKit",
                    level: .error
                )
                return
            }

            // The handler is called on a HealthKit background queue, so we hop to
            // MainActor before touching SwiftData or NotificationService. Keep
            // HealthKit's completion open until the async import finishes, otherwise
            // iOS can suspend the app before the notification is scheduled.
            healthKitRepository.registerObserverQuery { [weak self] completion in
                Task { @MainActor [weak self] in
                    guard let self else {
                        completion()
                        return
                    }
                    await self.handleNewWorkoutsDetected(source: "observer")
                    completion()
                }
            }
            AppLogger.log("HealthKit background workout observer registered.", label: "HealthKit", level: .info)
        }

        await handleNewWorkoutsDetected(source: "startup")
    }

    // MARK: Private

    private func handleNewWorkoutsDetected(source: String) async {
        // A trigger that lands mid-sync must not be dropped: the in-flight pass
        // snapshotted its existing-ID set before the workout that fired this
        // trigger existed, so it can miss it. Queue exactly one follow-up pass
        // and let the in-flight caller replay it (M1).
        guard !isSyncing else {
            pendingSyncSource = source
            AppLogger.log(
                "Sync already in progress; queued follow-up \(source) sync.",
                label: "HealthKit",
                level: .debug
            )
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        var currentSource: String? = source
        while let source = currentSource {
            await runSyncPass(source: source)
            currentSource = pendingSyncSource
            pendingSyncSource = nil
        }
    }

    private func runSyncPass(source: String) async {
        let existingIDs: Set<String>
        do {
            let stored = try context.fetch(FetchDescriptor<RunWorkout>())
            let tombstoned = try context.fetch(FetchDescriptor<DeletedWorkout>())
            existingIDs = Set(stored.compactMap(\.healthKitWorkoutID))
                .union(tombstoned.map(\.healthKitWorkoutID))
        } catch {
            AppLogger.log(
                "Failed to fetch existing workouts before HealthKit sync (\(source)): \(error.localizedDescription)",
                label: "HealthKit",
                level: .error
            )
            return
        }

        // On a fresh install or reinstall the local store is empty, so look back up to 90 days
        // to recover runs that may not have synced to CloudKit before the app was removed.
        // For normal syncs (store already has data) keep the window short for performance.
        let lookbackDays = existingIDs.isEmpty ? -90 : -7
        let cutoff = Calendar.current.date(byAdding: .day, value: lookbackDays, to: Date()) ?? Date()

        var newWorkouts: [RunWorkout]
        do {
            newWorkouts = try await fetchImportableWorkouts(
                from: cutoff,
                existingIDs: existingIDs,
                source: source
            )
            if newWorkouts.isEmpty, source == "observer" {
                AppLogger.log(
                    "Observer sync found no importable workouts; retrying after HealthKit settles.",
                    label: "HealthKit",
                    level: .debug
                )
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                newWorkouts = try await fetchImportableWorkouts(
                    from: cutoff,
                    existingIDs: existingIDs,
                    source: "\(source)-retry"
                )
            }
        } catch {
            AppLogger.log(
                "Failed to import HealthKit workouts (\(source)): \(error.localizedDescription)",
                label: "HealthKit",
                level: .error
            )
            return
        }

        if newWorkouts.isEmpty {
            AppLogger.log("No new HealthKit running workouts found during \(source) sync.", label: "HealthKit", level: .debug)
        } else {
            for workout in newWorkouts {
                context.insert(workout)
            }
            linkToScheduledWorkouts(newWorkouts)
            do {
                try context.save()
            } catch {
                AppLogger.log(
                    "Failed to save imported HealthKit workouts (\(source)): \(error.localizedDescription)",
                    label: "HealthKit",
                    level: .error
                )
            }

            for workout in newWorkouts {
                if let coordinate = workout.routeCoordinates.first {
                    await attachWeather(to: workout, coordinate: coordinate)
                }
            }

            if Self.shouldBatchSyncNotifications(count: newWorkouts.count) {
                // A large import (fresh-install 90-day recovery) fired one banner per
                // recovered run — 50+ simultaneous notifications. Send one summary
                // instead, and skip the auto-review sheet: surfacing one arbitrary
                // weeks-old run for review makes no sense for a bulk recovery (M5).
                try? await notificationService.notifyRunBatchSynced(count: newWorkouts.count)
            } else {
                let unit = AppSettings.syncedUnitPreference()
                for workout in newWorkouts {
                    try? await notificationService.notifyNewRunSynced(workout, unit: unit)
                }
                if let first = newWorkouts.first {
                    UserDefaults.standard.set(first.id.uuidString, forKey: "pendingReviewWorkoutID")
                }
                onWorkoutsSynced?(newWorkouts)
            }
            AppLogger.log(
                "Imported \(newWorkouts.count) HealthKit running workout(s) during \(source) sync.",
                label: "HealthKit",
                level: .info
            )
        }

        await syncStrengthWorkouts(source: source, lookbackCutoff: cutoff)
    }

    /// Imports larger than this send one summary notification instead of a
    /// banner per run. Small batches (a normal day's sync) keep the per-run
    /// banner with its tap-to-review flow.
    static let maxIndividualSyncNotifications = 3

    /// Whether an import of `count` runs should collapse to a single summary
    /// notification rather than one banner per run.
    static func shouldBatchSyncNotifications(count: Int) -> Bool {
        count > maxIndividualSyncNotifications
    }

    private func fetchImportableWorkouts(
        from cutoff: Date,
        existingIDs: Set<String>,
        source: String
    ) async throws -> [RunWorkout] {
        AppLogger.log(
            "Querying HealthKit running workouts for \(source) sync since \(cutoff.formatted(.iso8601)). Existing HK IDs: \(existingIDs.count).",
            label: "HealthKit",
            level: .debug
        )
        return try await healthKitRepository.fetchImportableWorkouts(
            from: cutoff,
            to: Date(),
            existingIDs: existingIDs
        )
    }

    /// Matches each newly imported `RunWorkout` to an unlinked, **run-type** `ScheduledWorkout`
    /// on the same calendar day (or the day before, allowing for late completions).
    ///
    /// This is the single linker for runs. It never considers strength, cross-training, or rest
    /// days as candidates (an imported run must not complete a gym day), and it never overwrites
    /// the run's own `workoutType` from the schedule — the run keeps the type inferred from its
    /// data; the schedule link records which planned session it fulfilled. Workout type is used
    /// only as a tiebreaker when several run days share the same date.
    private func linkToScheduledWorkouts(_ runWorkouts: [RunWorkout]) {
        let toLink = runWorkouts.filter { $0.scheduledWorkout == nil }
        guard !toLink.isEmpty else { return }

        let descriptor = FetchDescriptor<ScheduledWorkout>(
            predicate: #Predicate { $0.isCompleted == false }
        )
        guard let allIncomplete = try? context.fetch(descriptor) else { return }
        // Keep only run-type slots not already linked to another run.
        var available = allIncomplete.filter { $0.completedWorkout == nil && $0.workoutType.isRunType }

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
                match.completedWorkout = run
                match.isCompleted = true
                match.linkedRunWorkoutID = run.id
                run.linkedScheduledWorkoutID = match.id
                // Remove from available pool so it can't be matched twice.
                available.removeAll { $0.id == match.id }
            }
        }
    }

    // MARK: - Strength workout sync

    private func syncStrengthWorkouts(source: String, lookbackCutoff: Date) async {
        let stored: [StrengthWorkout]
        let existingIDs: Set<String>
        do {
            stored = try context.fetch(FetchDescriptor<StrengthWorkout>())
            let tombstoned = try context.fetch(FetchDescriptor<DeletedWorkout>())
            // Union tombstones so a deleted Watch gym session is not re-imported forever.
            existingIDs = Set(stored.compactMap(\.healthKitWorkoutID))
                .union(tombstoned.map(\.healthKitWorkoutID))
        } catch {
            AppLogger.log(
                "Failed to fetch existing strength workouts before HealthKit sync (\(source)): \(error.localizedDescription)",
                label: "HealthKit",
                level: .error
            )
            return
        }

        let hkWorkouts: [StrengthWorkout]
        do {
            hkWorkouts = try await healthKitRepository.fetchImportableStrengthWorkouts(
                from: lookbackCutoff,
                to: Date(),
                existingIDs: existingIDs
            )
        } catch {
            AppLogger.log(
                "Failed to import HealthKit strength workouts (\(source)): \(error.localizedDescription)",
                label: "HealthKit",
                level: .error
            )
            return
        }

        guard !hkWorkouts.isEmpty else { return }

        // Merge: if an in-app StrengthWorkout without a HK ID looks like the same
        // physical session as an imported one, stamp the HK UUID onto it instead
        // of creating a duplicate. Matching by same-day alone collapsed two
        // genuinely distinct same-day sessions (e.g. a morning app-log and an
        // evening Watch workout) into one, discarding the second; require the
        // start times to be close instead.
        var unlinked = stored.filter { $0.healthKitWorkoutID == nil }
        var toInsert: [StrengthWorkout] = []
        for hkWorkout in hkWorkouts {
            if let idx = unlinked.firstIndex(where: {
                Self.isSameStrengthSession($0.date, hkWorkout.date)
            }) {
                unlinked[idx].healthKitWorkoutID = hkWorkout.healthKitWorkoutID
                unlinked.remove(at: idx)
            } else {
                toInsert.append(hkWorkout)
            }
        }

        for workout in toInsert { context.insert(workout) }
        linkStrengthToScheduledWorkouts(toInsert)
        try? context.save()
        AppLogger.log(
            "Strength sync (\(source)): merged=\(hkWorkouts.count - toInsert.count), inserted=\(toInsert.count).",
            label: "HealthKit",
            level: .info
        )
    }

    /// Two strength sessions are treated as the same physical workout — and so
    /// deduplicated on import — only when their start times fall within this
    /// window. Generous enough to absorb the lag between finishing a session and
    /// logging it, but far tighter than "same calendar day", which merged
    /// unrelated morning/evening sessions.
    static let strengthMergeToleranceSeconds: TimeInterval = 3 * 60 * 60

    /// Whether two strength-session start dates are close enough to be the same
    /// workout for dedup purposes.
    static func isSameStrengthSession(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= strengthMergeToleranceSeconds
    }

    private func linkStrengthToScheduledWorkouts(_ workouts: [StrengthWorkout]) {
        let descriptor = FetchDescriptor<ScheduledWorkout>(
            predicate: #Predicate { $0.isCompleted == false }
        )
        guard let allIncomplete = try? context.fetch(descriptor) else { return }
        var available = allIncomplete.filter {
            $0.completedStrengthWorkout == nil && $0.workoutType == .strength
        }
        let calendar = Calendar.current
        var dirty = false
        for workout in workouts {
            let workoutDay = calendar.startOfDay(for: workout.date)
            if let match = available.first(where: {
                let scheduledDay = calendar.startOfDay(for: $0.scheduledDate)
                let diff = calendar.dateComponents([.day], from: scheduledDay, to: workoutDay).day ?? Int.max
                return diff >= 0 && diff <= 1
            }) {
                workout.scheduledWorkout = match
                match.completedStrengthWorkout = workout
                match.isCompleted = true
                match.linkedStrengthWorkoutID = workout.id
                workout.linkedScheduledWorkoutID = match.id
                available.removeAll { $0.id == match.id }
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
