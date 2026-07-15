import Foundation
import HealthKit
import CoreLocation
@preconcurrency import WorkoutKit

// MARK: - Protocol

protocol HealthKitRepositoryProtocol: Sendable {
    var isAvailable: Bool { get }
    /// Returns `true` if the user has already granted HealthKit write access.
    /// Does **not** prompt — reads existing authorization status only.
    var isAuthorized: Bool { get }
    func requestAuthorization() async throws
    @MainActor func save(_ workout: RunWorkout) async throws -> String
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout]
    /// Schedules each non-rest future workout in the plan as a WorkoutKit composition
    /// so it appears in the Apple Watch Workout app and the Fitness app.
    @MainActor func syncWorkoutPlans(for plan: TrainingPlan, unitPreference: UnitPreference) async throws
    /// Removes all WorkoutKit scheduled compositions for the plan.
    @MainActor func removeWorkoutPlans(for plan: TrainingPlan) async throws
    /// Fetches running workouts from HealthKit, converts them to RunWorkout models,
    /// and skips any whose HK UUID is already in `existingIDs`.
    @MainActor func fetchImportableWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>
    ) async throws -> [RunWorkout]
    /// Fetches strength workouts (traditional, functional, core) from HealthKit,
    /// converts them to StrengthWorkout models, and skips any whose HK UUID is
    /// already in `existingIDs`.
    @MainActor func fetchImportableStrengthWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>
    ) async throws -> [StrengthWorkout]
    /// Enables HealthKit background delivery for running workouts at `.immediate` frequency.
    /// Safe to call multiple times — HealthKit is idempotent.
    func enableBackgroundDelivery() async throws
    /// Registers a long-lived observer query that calls `handler` whenever new running
    /// workouts are written to HealthKit. The handler is invoked on an arbitrary
    /// background queue; callers are responsible for hopping to the appropriate actor.
    func registerObserverQuery(handler: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void)
}

// MARK: - Live implementation

private final class HealthKitObserverCompletion: @unchecked Sendable {
    private let completion: () -> Void

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    func callAsFunction() {
        completion()
    }
}

private enum HealthKitRepositoryError: LocalizedError {
    case workoutKitUnsupported
    case workoutKitNotAuthorized

    var errorDescription: String? {
        switch self {
        case .workoutKitUnsupported:
            return "WorkoutKit scheduling is not supported on this device."
        case .workoutKitNotAuthorized:
            return "WorkoutKit scheduling is not authorized."
        }
    }
}

final class HealthKitRepository: HealthKitRepositoryProtocol, @unchecked Sendable {
    private let store = HKHealthStore()
    // Retained so the observer is not deallocated after registration.
    private var observerQuery: HKObserverQuery?

    // WorkoutKit shows a scheduled workout as "upcoming" up until its scheduled instant, then
    // removes it the moment that instant passes. Workouts are stored at midnight (`startOfDay`),
    // so scheduling at that raw time meant a day's workout vanished at 00:00 — visible only as a
    // future day, never on the day itself. Anchoring to the END of the scheduled day instead keeps
    // each workout visible in the Workout app for the entire day it's planned for (today included)
    // and drops it only once that day is over.
    static func workoutKitFireDate(
        for scheduledDate: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let dayStart = calendar.startOfDay(for: scheduledDate)
        // End of the scheduled day: next midnight minus a minute (DST-safe via calendar math).
        guard let endOfDay = calendar.date(byAdding: DateComponents(day: 1, minute: -1), to: dayStart),
              endOfDay > now
        else { return nil }
        return endOfDay
    }

    private static let shareTypes: Set<HKSampleType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.heartRate)
    ]

    private static let readTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.heartRate),
        HKSeriesType.workoutRoute()
    ]

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    var isAuthorized: Bool {
        guard isAvailable else { return false }
        return store.authorizationStatus(for: .workoutType()) == .sharingAuthorized
    }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(
            toShare: Self.shareTypes,
            read: Self.readTypes
        )
    }

    // MARK: - Completed workout

    @MainActor func save(_ workout: RunWorkout) async throws -> String {
        let isIndoor = workout.workoutLocation == .indoor
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = isIndoor ? .indoor : .outdoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: workout.date)

        let distanceSample = HKQuantitySample(
            type: HKQuantityType(.distanceWalkingRunning),
            quantity: HKQuantity(unit: .meter(), doubleValue: workout.distanceMeters),
            start: workout.date,
            end: workout.date.addingTimeInterval(workout.durationSeconds)
        )
        try await builder.addSamples([distanceSample])

        try await builder.endCollection(at: workout.date.addingTimeInterval(workout.durationSeconds))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.addMetadata([
                "StrideWorkoutID": workout.id.uuidString,
                HKMetadataKeyIndoorWorkout: isIndoor
            ]) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        guard let hkWorkout = try await builder.finishWorkout() else {
            throw HKError(.errorNoData)
        }
        return hkWorkout.uuid.uuidString
    }

    // MARK: - Workout plans (WorkoutKit)

    @MainActor func syncWorkoutPlans(for plan: TrainingPlan, unitPreference: UnitPreference) async throws {
        guard WorkoutScheduler.isSupported else {
            throw HealthKitRepositoryError.workoutKitUnsupported
        }
        let scheduler = WorkoutScheduler.shared

        if await scheduler.authorizationState == .notDetermined {
            let state = await scheduler.requestAuthorization()
            guard state == .authorized else {
                throw HealthKitRepositoryError.workoutKitNotAuthorized
            }
        }
        guard await scheduler.authorizationState == .authorized else {
            throw HealthKitRepositoryError.workoutKitNotAuthorized
        }

        let allWorkouts = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }
        let syncableWorkouts = allWorkouts.filter {
            $0.workoutType != .rest &&
            !$0.isCompleted
        }
        var existingIDs = Set(allWorkouts.map { $0.id.uuidString })
        existingIDs.formUnion(allWorkouts.compactMap(\.healthKitPlanID))
        if !existingIDs.isEmpty {
            let scheduled = await scheduler.scheduledWorkouts
            for entry in scheduled where existingIDs.contains(entry.plan.id.uuidString) {
                await scheduler.remove(entry.plan, at: entry.date)
            }
            allWorkouts.forEach { $0.healthKitPlanID = nil }
        }

        let calendar = Calendar.current
        let now = Date()
        for workout in syncableWorkouts {
            guard let fireDate = Self.workoutKitFireDate(for: workout.scheduledDate, now: now, calendar: calendar)
            else { continue }

            let dateComponents = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )
            let workoutPlan = makeWorkoutPlan(for: workout, unitPreference: unitPreference)
            await scheduler.schedule(workoutPlan, at: dateComponents)
            workout.healthKitPlanID = workoutPlan.id.uuidString
        }
    }

    @MainActor func removeWorkoutPlans(for plan: TrainingPlan) async throws {
        let allWorkouts = (plan.weeks ?? []).flatMap { $0.workouts ?? [] }

        // Clear the local tracking IDs only once removal has actually run.
        // Nulling them on an unsupported/unauthorized early return (as the old
        // `defer` did) would permanently orphan the scheduled Watch workouts —
        // they'd stay on the Watch but no longer be findable for removal.
        guard WorkoutScheduler.isSupported else { return }
        let scheduler = WorkoutScheduler.shared
        guard await scheduler.authorizationState == .authorized else { return }

        let ids = Set(allWorkouts.compactMap(\.healthKitPlanID))
        guard !ids.isEmpty else { return }

        let scheduled = await scheduler.scheduledWorkouts
        for entry in scheduled where ids.contains(entry.plan.id.uuidString) {
            await scheduler.remove(entry.plan, at: entry.date)
        }
        allWorkouts.forEach { $0.healthKitPlanID = nil }
    }

    // MARK: - WorkoutKit plan builder

    private func makeWorkoutPlan(for workout: ScheduledWorkout, unitPreference: UnitPreference) -> WorkoutPlan {
        // Use the scheduled workout's own UUID so the plan ID is stable across syncs.
        let planID = workout.id

        // Strength workouts → SingleGoalWorkout with a strength activity so the Watch starts a
        // strength session, not a run. (All the builders below assume a running activity.)
        if workout.workoutType == .strength {
            let goal: WorkoutGoal
            if let minutes = workout.strengthPlan?.estimatedDurationMinutes, minutes > 0 {
                goal = .time(Double(minutes) * 60, UnitDuration.seconds)
            } else {
                goal = .open
            }
            let strength = SingleGoalWorkout(
                activity: .functionalStrengthTraining,
                location: .indoor,
                goal: goal
            )
            return WorkoutPlan(.goal(strength), id: planID)
        }

        // Cross-training days → a cross-training activity so the Watch starts the
        // right session rather than a run. (The builders below all assume
        // running.) The modality is unspecified, so use an open goal.
        if workout.workoutType == .crossTraining {
            let crossTraining = SingleGoalWorkout(
                activity: .crossTraining,
                location: workout.workoutLocation == .indoor ? .indoor : .outdoor,
                goal: .open
            )
            return WorkoutPlan(.goal(crossTraining), id: planID)
        }

        // Structured workouts (warmup + interval blocks + cooldown) → CustomWorkout.
        if let structure = workout.workoutStructure, !structure.mainSets.isEmpty {
            let custom = makeCustomWorkout(from: structure, workout: workout, unitPreference: unitPreference)
            return WorkoutPlan(.custom(custom), id: planID)
        }

        // Flat interval workouts → CustomWorkout with explicit repeat blocks.
        if workout.workoutType == .interval, !workout.intervals.isEmpty {
            let custom = makeCustomWorkoutLegacy(for: workout, unitPreference: unitPreference)
            return WorkoutPlan(.custom(custom), id: planID)
        }

        // Tempo runs with a distance + pace target → PacerWorkout.
        // Apple Watch derives and displays the target pace from the distance/time pair.
        if workout.workoutType == .tempo,
           let distMeters = workout.targetDistanceMeters,
           let paceRange = workout.targetPaceRange {
            let midPaceSPerKm = (paceRange.lowerBound + paceRange.upperBound) / 2
            let targetDurationSeconds = (distMeters / 1_000) * midPaceSPerKm
            let pacer = PacerWorkout(
                activity: .running,
                location: workout.workoutLocation == .indoor ? .indoor : .outdoor,
                distance: distanceMeasurement(meters: distMeters, unitPreference: unitPreference),
                time: Measurement(value: targetDurationSeconds, unit: UnitDuration.seconds)
            )
            return WorkoutPlan(.pacer(pacer), id: planID)
        }

        // Remaining workouts (distance-goal or open-ended) → CustomWorkout.
        let custom = makeCustomWorkoutLegacy(for: workout, unitPreference: unitPreference)
        return WorkoutPlan(.custom(custom), id: planID)
    }

    /// Builds a ``CustomWorkout`` from a ``WorkoutStructure`` with precise distance/time goals.
    private func makeCustomWorkout(
        from structure: WorkoutStructure,
        workout: ScheduledWorkout,
        unitPreference: UnitPreference
    ) -> CustomWorkout {
        let warmupGoal: WorkoutGoal = structure.warmup.distanceMeters
            .map { distanceGoal(meters: $0, unitPreference: unitPreference) } ?? .open
        let warmupName: String? = structure.warmup.label.isEmpty ? nil : structure.warmup.label
        let warmupStep = WorkoutStep(goal: warmupGoal, alert: nil, displayName: warmupName)

        let blocks: [IntervalBlock] = structure.mainSets.map { set in
            let workGoal: WorkoutGoal
            if let dist = set.workSegment.distanceMeters {
                workGoal = distanceGoal(meters: dist, unitPreference: unitPreference)
            } else if let dur = set.workSegment.durationSeconds {
                workGoal = .time(dur, UnitDuration.seconds)
            } else {
                workGoal = .open
            }
            let workStep = IntervalStep(.work, goal: workGoal, alert: nil)

            var steps: [IntervalStep] = [workStep]
            if let recDur = set.recoverySegment.durationSeconds, recDur > 0 {
                steps.append(IntervalStep(
                    .recovery,
                    goal: .time(recDur, UnitDuration.seconds),
                    alert: nil
                ))
            } else if let recDist = set.recoverySegment.distanceMeters, recDist > 0 {
                steps.append(IntervalStep(
                    .recovery,
                    goal: distanceGoal(meters: recDist, unitPreference: unitPreference),
                    alert: nil
                ))
            }

            return IntervalBlock(steps: steps, iterations: set.repetitions)
        }

        let cooldownGoal: WorkoutGoal = structure.cooldown.distanceMeters
            .map { distanceGoal(meters: $0, unitPreference: unitPreference) } ?? .open
        let cooldownName: String? = structure.cooldown.label.isEmpty ? nil : structure.cooldown.label
        let cooldownStep = WorkoutStep(goal: cooldownGoal, alert: nil, displayName: cooldownName)

        return CustomWorkout(
            activity: .running,
            location: workout.workoutLocation == .indoor ? .indoor : .outdoor,
            displayName: workout.workoutType.displayName,
            warmup: warmupStep,
            blocks: blocks,
            cooldown: cooldownStep
        )
    }

    /// Legacy path for workouts without a ``WorkoutStructure`` (flat interval array).
    private func makeCustomWorkoutLegacy(for workout: ScheduledWorkout, unitPreference: UnitPreference) -> CustomWorkout {
        let warmup   = WorkoutStep(goal: .open, alert: nil)
        let cooldown = WorkoutStep(goal: .open, alert: nil)
        let blocks: [IntervalBlock]

        if workout.workoutType == .interval && !workout.intervals.isEmpty {
            blocks = workout.intervals.map { interval in
                let workGoal: WorkoutGoal
                if let distance = interval.distanceMeters {
                    workGoal = distanceGoal(meters: distance, unitPreference: unitPreference)
                } else if let duration = interval.durationSeconds {
                    workGoal = .time(duration, UnitDuration.seconds)
                } else {
                    workGoal = .open
                }
                let workStep = IntervalStep(.work, goal: workGoal, alert: nil)
                let restStep = IntervalStep(
                    .recovery,
                    goal: .time(interval.recoverySeconds, UnitDuration.seconds),
                    alert: nil
                )
                return IntervalBlock(steps: [workStep, restStep], iterations: interval.repetitions)
            }
        } else {
            let goal: WorkoutGoal = workout.targetDistanceMeters
                .map { distanceGoal(meters: $0, unitPreference: unitPreference) } ?? .open
            let workStep = IntervalStep(.work, goal: goal, alert: nil)
            blocks = [IntervalBlock(steps: [workStep], iterations: 1)]
        }

        return CustomWorkout(
            activity: .running,
            location: workout.workoutLocation == .indoor ? .indoor : .outdoor,
            displayName: workout.workoutType.displayName,
            warmup: warmup,
            blocks: blocks,
            cooldown: cooldown
        )
    }

    private func distanceMeasurement(meters: Double, unitPreference: UnitPreference) -> Measurement<UnitLength> {
        switch unitPreference {
        case .metric:   return Measurement(value: meters / 1_000, unit: .kilometers)
        case .imperial: return Measurement(value: meters / 1_609.344, unit: .miles)
        }
    }

    private func distanceGoal(meters: Double, unitPreference: UnitPreference) -> WorkoutGoal {
        switch unitPreference {
        case .metric:
            return .distance(meters / 1_000, UnitLength.kilometers)
        case .imperial:
            return .distance(meters / 1_609.344, UnitLength.miles)
        }
    }

    // MARK: - Background delivery & observer

    func enableBackgroundDelivery() async throws {
        guard isAvailable else { return }
        try await store.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)
    }

    func registerObserverQuery(handler: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) {
        guard isAvailable else { return }
        // Observe all running workouts (outdoor and treadmill share the .running activity type)
        let query = HKObserverQuery(
            sampleType: .workoutType(),
            predicate: nil
        ) { _, completionHandler, error in
            guard error == nil else {
                AppLogger.log(
                    "HealthKit observer update failed: \(error?.localizedDescription ?? "unknown error")",
                    label: "HealthKit",
                    level: .warning
                )
                completionHandler()
                return
            }
            let completion = HealthKitObserverCompletion(completionHandler)
            handler { completion() }
        }
        observerQuery = query
        store.execute(query)
    }

    // MARK: - Historical workout fetch

    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        // Fetch both outdoor and indoor (treadmill) running workouts
        let outdoorPredicate = HKQuery.predicateForWorkouts(with: .running)
        let datePredicate = HKQuery.predicateForSamples(
            withStart: startDate, end: endDate, options: .strictStartDate
        )
        let compound = NSCompoundPredicate(
            andPredicateWithSubpredicates: [outdoorPredicate, datePredicate]
        )
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: compound,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
                }
            }
            store.execute(query)
        }
        if workouts.isEmpty {
            await logRecentWorkoutDiagnostics(from: startDate, to: endDate)
        } else {
            AppLogger.log(
                "HealthKit returned \(workouts.count) running workout(s): \(workoutSummaries(workouts))",
                label: "HealthKit",
                level: .debug
            )
        }
        return workouts
    }

    // MARK: - Import workouts from HealthKit

    /// Whether a HealthKit running workout carries enough substance to import,
    /// as opposed to a tiny "shell" left by an accidental start/stop. A genuine
    /// run has both a real distance **and** a non-trivial duration; a 0 m,
    /// 30-second entry (previously admitted by an `||` guard) is noise that
    /// pollutes pace/VDOT stats.
    static func isImportableWorkout(distanceMeters: Double, durationSeconds: Double) -> Bool {
        distanceMeters > 100 && durationSeconds >= 30
    }

    /// Fetches running workouts from HealthKit in the given range, converts each to a
    /// `RunWorkout` (with heart rate and elevation from associated HealthKit samples),
    /// and returns only those whose HK UUID is not already in `existingIDs`.
    @MainActor func fetchImportableWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>
    ) async throws -> [RunWorkout] {
        let hkWorkouts = try await fetchWorkouts(from: startDate, to: endDate)
        var result: [RunWorkout] = []
        var skippedExisting = 0
        var skippedTinyShell = 0

        for hkWorkout in hkWorkouts {
            let hkID = hkWorkout.uuid.uuidString
            guard !existingIDs.contains(hkID) else {
                skippedExisting += 1
                continue
            }

            let workoutDistanceMeters = hkWorkout.totalDistance?.doubleValue(for: .meter()) ?? 0
            let distanceMeters: Double
            if workoutDistanceMeters > 0 {
                distanceMeters = workoutDistanceMeters
            } else {
                distanceMeters = (try? await fetchDistanceMeters(for: hkWorkout)) ?? 0
                if distanceMeters > 0 {
                    AppLogger.log(
                        "Recovered \(Int(distanceMeters))m from distance samples for HealthKit workout \(hkID.prefix(8)).",
                        label: "HealthKit",
                        level: .debug
                    )
                }
            }
            guard Self.isImportableWorkout(distanceMeters: distanceMeters, durationSeconds: hkWorkout.duration) else {
                skippedTinyShell += 1
                continue
            }

            let hrStats = try? await fetchHeartRateStats(for: hkWorkout)
            let elevation = elevationGain(from: hkWorkout)
            let coordinates = await fetchRouteCoordinates(for: hkWorkout)

            let isIndoor = (hkWorkout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? false
            let run = RunWorkout(
                date: hkWorkout.startDate,
                distanceMeters: distanceMeters,
                durationSeconds: hkWorkout.duration,
                workoutType: inferWorkoutType(distanceMeters: distanceMeters, durationSeconds: hkWorkout.duration),
                workoutLocation: isIndoor ? .indoor : .outdoor
            )
            run.averageHeartRate = hrStats?.avg
            run.maxHeartRate = hrStats?.max
            run.elevationGainMeters = elevation
            run.healthKitWorkoutID = hkID
            if !coordinates.isEmpty { run.routeCoordinates = coordinates }
            result.append(run)
        }
        AppLogger.log(
            "HealthKit import candidates: fetched=\(hkWorkouts.count), importable=\(result.count), existing=\(skippedExisting), tinyShell=\(skippedTinyShell)",
            label: "HealthKit",
            level: .debug
        )
        return result
    }

    // MARK: - Strength workout import

    private func fetchStrengthHKWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        let activityTypes: [HKWorkoutActivityType] = [
            .traditionalStrengthTraining,
            .functionalStrengthTraining,
            .coreTraining
        ]
        let typePredicate = NSCompoundPredicate(
            orPredicateWithSubpredicates: activityTypes.map { HKQuery.predicateForWorkouts(with: $0) }
        )
        let datePredicate = HKQuery.predicateForSamples(
            withStart: startDate, end: endDate, options: .strictStartDate
        )
        let compound = NSCompoundPredicate(andPredicateWithSubpredicates: [typePredicate, datePredicate])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: compound,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
                }
            }
            store.execute(query)
        }
    }

    @MainActor func fetchImportableStrengthWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>
    ) async throws -> [StrengthWorkout] {
        let hkWorkouts = try await fetchStrengthHKWorkouts(from: startDate, to: endDate)
        var result: [StrengthWorkout] = []
        var skippedExisting = 0

        for hkWorkout in hkWorkouts {
            let hkID = hkWorkout.uuid.uuidString
            guard !existingIDs.contains(hkID) else { skippedExisting += 1; continue }
            guard hkWorkout.duration >= 60 else { continue }

            let workout = StrengthWorkout(date: hkWorkout.startDate, durationSeconds: hkWorkout.duration)
            workout.healthKitWorkoutID = hkID
            result.append(workout)
        }
        AppLogger.log(
            "HealthKit strength import: fetched=\(hkWorkouts.count), importable=\(result.count), existing=\(skippedExisting)",
            label: "HealthKit",
            level: .debug
        )
        return result
    }

    // MARK: - HealthKit sample helpers

    private func fetchDistanceMeters(for workout: HKWorkout) async throws -> Double {
        let distanceType = HKQuantityType(.distanceWalkingRunning)
        let workoutPredicate = HKQuery.predicateForObjects(from: workout)
        let datePredicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: [.strictStartDate, .strictEndDate]
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            workoutPredicate,
            datePredicate
        ])

        let stats: HKStatistics? = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: distanceType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
            store.execute(query)
        }
        return stats?.sumQuantity()?.doubleValue(for: .meter()) ?? 0
    }

    private func fetchRouteCoordinates(for workout: HKWorkout) async -> [Coordinate] {
        let predicate = HKQuery.predicateForObjects(from: workout)

        // Step 1: find the HKWorkoutRoute sample(s) for this workout
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }

        guard !routes.isEmpty else { return [] }

        // Step 2: stream CLLocation objects from every route segment. A paused/
        // resumed workout produces multiple HKWorkoutRoute samples; reading only
        // `routes.first` dropped the later segments.
        var coordinates: [Coordinate] = []
        for route in routes {
            let segment: [Coordinate] = await withCheckedContinuation { continuation in
                var collected: [Coordinate] = []
                var didResume = false
                let routeQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                    if let locations {
                        collected += locations.map { Coordinate($0.coordinate) }
                    }
                    // Resume exactly once — on completion or on error. Ignoring
                    // the error and resuming only on `done` let a failed callback
                    // hang the entire serial import forever.
                    if (done || error != nil), !didResume {
                        didResume = true
                        continuation.resume(returning: collected)
                    }
                }
                store.execute(routeQuery)
            }
            coordinates += segment
        }

        return coordinates
    }

    private func fetchHeartRateStats(for workout: HKWorkout) async throws -> (avg: Double?, max: Double?) {
        let hrType = HKQuantityType(.heartRate)
        // Scope to samples associated with this workout (like the distance query
        // does), not merely those in its time window. A time-only predicate lets
        // chest-strap or overlapping samples from other sources skew avg/max HR.
        let workoutPredicate = HKQuery.predicateForObjects(from: workout)
        let datePredicate = HKQuery.predicateForSamples(
            withStart: workout.startDate, end: workout.endDate, options: .strictStartDate
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            workoutPredicate,
            datePredicate
        ])
        let stats: HKStatistics? = try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsQuery(
                quantityType: hrType,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMax]
            ) { _, result, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: result) }
            }
            store.execute(query)
        }
        let bpmUnit = HKUnit(from: "count/min")
        return (
            avg: stats?.averageQuantity()?.doubleValue(for: bpmUnit),
            max: stats?.maximumQuantity()?.doubleValue(for: bpmUnit)
        )
    }

    /// Reads cumulative elevation ascended from the workout's metadata.
    /// Apple Watch workouts store this under HKMetadataKeyElevationAscended.
    private func elevationGain(from workout: HKWorkout) -> Double? {
        guard let quantity = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity else {
            return nil
        }
        return quantity.doubleValue(for: .meter())
    }

    // MARK: - Helpers

    /// Infers a broad workout type from distance and pace.
    /// Apple Health has no concept of Easy/Tempo/LongRun, so we approximate.
    private func inferWorkoutType(distanceMeters: Double, durationSeconds: Double) -> WorkoutType {
        let distanceKm = distanceMeters / 1_000
        let paceSecPerKm = distanceMeters > 0 ? durationSeconds / distanceMeters * 1_000 : 400
        if distanceKm >= 16 { return .longRun }
        if paceSecPerKm < 320 { return .tempo }
        return .easy
    }

    private func logRecentWorkoutDiagnostics(from startDate: Date, to endDate: Date) async {
        let datePredicate = HKQuery.predicateForSamples(
            withStart: startDate, end: endDate, options: .strictStartDate
        )
        let workouts: [HKWorkout] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: datePredicate,
                limit: 10,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
                ]
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        guard !workouts.isEmpty else {
            AppLogger.log(
                "HealthKit returned no workouts of any type in the sync window. Check Stride's Health read permission for Workouts.",
                label: "HealthKit",
                level: .warning
            )
            return
        }
        AppLogger.log(
            "HealthKit returned no running workouts. Recent workouts of any type: \(workoutSummaries(workouts))",
            label: "HealthKit",
            level: .warning
        )
    }

    private func workoutSummaries(_ workouts: [HKWorkout]) -> String {
        workouts.map { workout in
            let id = workout.uuid.uuidString.prefix(8)
            let distance = workout.totalDistance?.doubleValue(for: .meter()) ?? 0
            let source = workout.sourceRevision.source.bundleIdentifier
            return "\(id) type=\(workout.workoutActivityType.rawValue) dist=\(Int(distance))m duration=\(Int(workout.duration))s source=\(source)"
        }
        .joined(separator: "; ")
    }
}
