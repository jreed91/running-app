import Foundation
import HealthKit
import CoreLocation
@preconcurrency import WorkoutKit

// MARK: - Import context

/// What the importer needs to know about the runner to interpret raw HealthKit data:
/// their own training paces, so a run's type is classified relative to them rather
/// than against one absolute threshold (N10), and the unit its splits are bucketed
/// in, matching how the live tracker records them (N9).
///
/// Both are optional in effect: with no pace estimate a run is `.easy` unless its
/// distance makes it a long run, and the split unit defaults to metric.
struct WorkoutImportContext: Sendable {
    var paces: TrainingPaces?
    var splitUnit: UnitPreference

    init(paces: TrainingPaces? = nil, splitUnit: UnitPreference = .metric) {
        self.paces = paces
        self.splitUnit = splitUnit
    }

    /// No runner context available — used by callers that have no profile to hand.
    static let unknownRunner = WorkoutImportContext()
}

// MARK: - Protocol

protocol HealthKitRepositoryProtocol: Sendable {
    var isAvailable: Bool { get }
    /// Returns `true` if the user has already granted HealthKit write access.
    /// Does **not** prompt — reads existing authorization status only.
    var isAuthorized: Bool { get }
    func requestAuthorization() async throws
    @MainActor func save(_ workout: RunWorkout) async throws -> String
    /// Writes an app-logged strength session to HealthKit and returns its HK UUID string.
    /// Without this a session logged in Stride earns no Activity-ring credit and never
    /// appears in Fitness (N14); the returned id also makes the Watch-vs-app merge exact
    /// instead of leaning on the ±3 h time heuristic.
    @MainActor func save(_ workout: StrengthWorkout) async throws -> String
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout]
    /// Schedules each non-rest future workout in the plan as a WorkoutKit composition
    /// so it appears in the Apple Watch Workout app and the Fitness app.
    @MainActor func syncWorkoutPlans(for plan: TrainingPlan, unitPreference: UnitPreference) async throws
    /// Removes all WorkoutKit scheduled compositions for the plan.
    @MainActor func removeWorkoutPlans(for plan: TrainingPlan) async throws
    /// Fetches running workouts from HealthKit, converts them to RunWorkout models,
    /// and skips any whose HK UUID is already in `existingIDs`. `context` supplies the
    /// runner's paces and split unit; pass `.unknownRunner` when neither is known.
    @MainActor func fetchImportableWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>,
        context: WorkoutImportContext
    ) async throws -> [RunWorkout]
    /// Fetches walking workouts from HealthKit, converts them to `RunWorkout` models
    /// carrying ``WorkoutType/walk``, and skips any whose HK UUID is already in
    /// `existingIDs` (N38).
    ///
    /// Same model, same enrichment and the same split bucketing as a run — a walk has a
    /// route, a heart rate and a pace like anything else, and reusing the model is what
    /// gives it the history row, the map and the charts. What it does not share is the
    /// classification: a walk is always `.walk`, never inferred against the runner's
    /// paces, and never counted as running (see `Sequence.runsOnly`).
    @MainActor func fetchImportableWalkingWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>,
        context: WorkoutImportContext
    ) async throws -> [RunWorkout]
    /// Fetches the `CrossTrainingImportPolicy` activities as `RunWorkout` models carrying
    /// ``WorkoutType/crossTraining``, skipping any already in `existingIDs` (B8). No
    /// walking/running samples are read, so a session has no splits, pace or cadence.
    @MainActor func fetchImportableCrossTrainingWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>,
        context: WorkoutImportContext
    ) async throws -> [RunWorkout]
    /// Fetches strength workouts (traditional, functional, core) from HealthKit,
    /// converts them to StrengthWorkout models, and skips any whose HK UUID is
    /// already in `existingIDs`.
    @MainActor func fetchImportableStrengthWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>
    ) async throws -> [StrengthWorkout]
    /// Fetches the raw heart-rate bpm sample series for a previously-imported workout,
    /// identified by its HealthKit UUID string. Used to backfill the time-in-zone chart
    /// for runs imported before HR samples were persisted (A6). Returns `[]` if the
    /// workout or its samples can't be found.
    func fetchHeartRateSamples(forWorkoutID id: String) async -> [Double]
    /// Fetches the cumulative distance series for a previously-imported workout,
    /// identified by its HealthKit UUID string. Used to backfill splits onto runs
    /// imported before the importer bucketed them (N9), the same way
    /// `fetchHeartRateSamples(forWorkoutID:)` backfills heart rate. Returns `[]` if the
    /// workout or its samples can't be found.
    func fetchDistanceSeries(forWorkoutID id: String) async -> [SplitBucketing.DistancePoint]
    /// The most recent body-mass sample in kilograms, or `nil` when there is none, the
    /// type is unauthorized, or HealthKit is unavailable.
    ///
    /// Read-only and never written: a running app has no business recording someone's
    /// weight. It exists so the coach's fuelling advice can be an amount rather than a
    /// guideline range — carbohydrate and fluid guidance is written per kilogram, so
    /// without a mass the cards can only quote both ends of a wide band.
    ///
    /// Returns `nil` rather than throwing on every failure path. A missing weight
    /// degrades one line of one card to a range; it is never worth surfacing an error
    /// for, and HealthKit reports "denied" and "no samples" identically anyway.
    func fetchLatestBodyMassKilograms() async -> Double?
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
        HKQuantityType(.heartRate),
        HKSeriesType.workoutRoute()
    ]

    private static let readTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.heartRate),
        // Read-only, and only ever summed inside a workout's own window: it is how an
        // imported run gets a cadence, which the app's own runs take from the pedometer
        // (A5). Nothing is ever written to it — the app's runs are already counted by the
        // device that took the steps, and writing them again would double them.
        //
        // A runner who authorized before this type was added is not re-prompted until
        // `requestAuthorization` runs again (onboarding, or Settings). Until then the
        // cadence query returns no data and imported runs simply carry no cadence, which
        // is the same state a treadmill import lands in — a missing stat, not an error.
        HKQuantityType(.stepCount),
        // Read-only, and read exactly once per launch to personalise the coach's fuelling
        // amounts (carbohydrate and fluid guidance is written per kilogram). Nothing is
        // ever written to it — a running app has no business recording someone's weight,
        // and the Settings field is a local fallback rather than a Health entry.
        //
        // As with `stepCount`, a runner who authorized before this type was added is not
        // re-prompted until `requestAuthorization` runs again. Until then the query
        // returns nothing and the cards quote guideline ranges, which is the same state
        // a runner who has never weighed themselves lands in.
        HKQuantityType(.bodyMass),
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
        let start = workout.date
        let end = start.addingTimeInterval(workout.durationSeconds)

        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = isIndoor ? .indoor : .outdoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: start)

        var samples: [HKSample] = [
            HKQuantitySample(
                type: HKQuantityType(.distanceWalkingRunning),
                quantity: HKQuantity(unit: .meter(), doubleValue: workout.distanceMeters),
                start: start,
                end: end
            )
        ]

        // Heart rate captured during the run: without these, an exported workout
        // shows a distance and nothing else in the Fitness app, and Stride's own
        // re-import can't rebuild time-in-zone from it.
        samples.append(contentsOf: Self.heartRateSamples(bpms: workout.heartRateSamples, start: start, end: end))

        try await builder.addSamples(samples)

        try await builder.endCollection(at: end)

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

        // The GPS trace is attached after the workout exists, since a route series
        // has to be associated with a saved workout. A route failure must not lose
        // the workout that was already written, so it is logged rather than thrown.
        if !isIndoor {
            do {
                try await saveRoute(coordinates: workout.routeCoordinates, for: hkWorkout, start: start, end: end)
            } catch {
                AppLogger.log("Failed to attach workout route to HealthKit: \(error)", label: "HealthKit", level: .error)
            }
        }

        return hkWorkout.uuid.uuidString
    }

    /// Exports an app-logged strength session (N14).
    ///
    /// The activity type matches what the importer reads back
    /// (`fetchStrengthHKWorkouts`), so a session written here is recognised as the
    /// same session if it ever comes back through an import, and the returned UUID
    /// lets `WorkoutSyncService` merge by identity rather than by the ±3 h
    /// same-session heuristic.
    @MainActor func save(_ workout: StrengthWorkout) async throws -> String {
        let start = workout.date
        let end = start.addingTimeInterval(workout.durationSeconds)

        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: start)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.addMetadata(["StrideWorkoutID": workout.id.uuidString]) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        try await builder.endCollection(at: end)

        guard let hkWorkout = try await builder.finishWorkout() else {
            throw HKError(.errorNoData)
        }
        return hkWorkout.uuid.uuidString
    }

    /// Evenly spaced timestamps for `count` samples spanning `start...end`.
    ///
    /// Stride stores heart-rate readings and route points as ordered arrays without
    /// their own timestamps, so they are laid back out across the workout's duration
    /// on export. Pure and deterministic so it can be tested directly.
    static func sampleTimestamps(count: Int, start: Date, end: Date) -> [Date] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [start] }
        let span = max(end.timeIntervalSince(start), 0)
        let step = span / Double(count - 1)
        return (0..<count).map { start.addingTimeInterval(step * Double($0)) }
    }

    private static func heartRateSamples(bpms: [Double], start: Date, end: Date) -> [HKQuantitySample] {
        guard !bpms.isEmpty else { return [] }
        let type = HKQuantityType(.heartRate)
        let unit = HKUnit.count().unitDivided(by: .minute())
        let timestamps = sampleTimestamps(count: bpms.count, start: start, end: end)
        return zip(bpms, timestamps).compactMap { bpm, timestamp in
            guard bpm > 0 else { return nil }
            return HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: bpm),
                start: timestamp,
                end: timestamp
            )
        }
    }

    @MainActor
    private func saveRoute(
        coordinates: [Coordinate],
        for hkWorkout: HKWorkout,
        start: Date,
        end: Date
    ) async throws {
        guard coordinates.count > 1 else { return }
        let timestamps = Self.sampleTimestamps(count: coordinates.count, start: start, end: end)
        let locations = zip(coordinates, timestamps).map { coordinate, timestamp in
            CLLocation(
                coordinate: coordinate.clCoordinate,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: -1,
                timestamp: timestamp
            )
        }
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        try await routeBuilder.insertRouteData(locations)
        _ = try await routeBuilder.finishRoute(with: hkWorkout, metadata: nil)
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
        // Distance, then duration, then open — the same order the work segments below use.
        // A time-based bookend used to fall through to `.open`, which quietly turned a
        // prescribed five-minute walk into "run until you press next" on the Watch. Every
        // pregnancy-plan session is built that way, and so is any structure that measures a
        // warm-up in minutes.
        let warmupGoal: WorkoutGoal
        if let dist = structure.warmup.distanceMeters {
            warmupGoal = distanceGoal(meters: dist, unitPreference: unitPreference)
        } else if let duration = structure.warmup.durationSeconds, duration > 0 {
            warmupGoal = .time(duration, UnitDuration.seconds)
        } else {
            warmupGoal = .open
        }
        let warmupName: String? = structure.warmup.label.isEmpty ? nil : structure.warmup.label
        let warmupStep = WorkoutStep(
            goal: warmupGoal,
            alert: paceAlert(secondsPerKm: structure.warmup.targetPaceSecondsPerKm),
            displayName: warmupName
        )

        let blocks: [IntervalBlock] = structure.mainSets.map { set in
            let workGoal: WorkoutGoal
            if let dist = set.workSegment.distanceMeters {
                workGoal = distanceGoal(meters: dist, unitPreference: unitPreference)
            } else if let dur = set.workSegment.durationSeconds {
                workGoal = .time(dur, UnitDuration.seconds)
            } else {
                workGoal = .open
            }
            // Attach the segment's target pace as a speed alert so the Watch
            // coaches pace per rep, not just when to switch steps.
            let workStep = IntervalStep(
                .work,
                goal: workGoal,
                alert: paceAlert(secondsPerKm: set.workSegment.targetPaceSecondsPerKm)
            )

            var steps: [IntervalStep] = [workStep]
            if let recDur = set.recoverySegment.durationSeconds, recDur > 0 {
                steps.append(IntervalStep(
                    .recovery,
                    goal: .time(recDur, UnitDuration.seconds),
                    alert: paceAlert(secondsPerKm: set.recoverySegment.targetPaceSecondsPerKm)
                ))
            } else if let recDist = set.recoverySegment.distanceMeters, recDist > 0 {
                steps.append(IntervalStep(
                    .recovery,
                    goal: distanceGoal(meters: recDist, unitPreference: unitPreference),
                    alert: paceAlert(secondsPerKm: set.recoverySegment.targetPaceSecondsPerKm)
                ))
            }

            return IntervalBlock(steps: steps, iterations: set.repetitions)
        }

        let cooldownGoal: WorkoutGoal
        if let dist = structure.cooldown.distanceMeters {
            cooldownGoal = distanceGoal(meters: dist, unitPreference: unitPreference)
        } else if let duration = structure.cooldown.durationSeconds, duration > 0 {
            cooldownGoal = .time(duration, UnitDuration.seconds)
        } else {
            cooldownGoal = .open
        }
        let cooldownName: String? = structure.cooldown.label.isEmpty ? nil : structure.cooldown.label
        let cooldownStep = WorkoutStep(
            goal: cooldownGoal,
            alert: paceAlert(secondsPerKm: structure.cooldown.targetPaceSecondsPerKm),
            displayName: cooldownName
        )

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

    /// Builds a WorkoutKit speed-range alert from a segment's target pace so the
    /// scheduled Watch workout coaches pace, not just structure. Returns `nil`
    /// (no alert) when the segment prescribes no pace, e.g. an open recovery.
    private func paceAlert(secondsPerKm pace: Double?) -> (any WorkoutAlert)? {
        guard let pace,
              let range = WorkoutPaceAlert.speedRangeMetersPerSecond(forPaceSecondsPerKm: pace)
        else { return nil }
        let lower = Measurement(value: range.lowerBound, unit: UnitSpeed.metersPerSecond)
        let upper = Measurement(value: range.upperBound, unit: UnitSpeed.metersPerSecond)
        return SpeedRangeAlert(target: lower...upper, metric: .current)
    }

    // MARK: - Background delivery & observer

    func enableBackgroundDelivery() async throws {
        guard isAvailable else { return }
        try await store.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)
    }

    func registerObserverQuery(handler: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) {
        guard isAvailable else { return }
        // Unfiltered on purpose: the sync pass behind this handler imports runs, walks and
        // strength sessions, so the observer has to fire for all of them.
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
    /// as opposed to a tiny "shell" left by an accidental start/stop.
    ///
    /// Delegates to ``RunEffortPolicy`` so the importer and the in-app run finish
    /// path share one floor rather than each carrying their own (N17).
    static func isImportableWorkout(distanceMeters: Double, durationSeconds: Double) -> Bool {
        RunEffortPolicy.isRealRun(distanceMeters: distanceMeters, durationSeconds: durationSeconds)
    }

    /// Which activity an import pass is converting.
    ///
    /// Runs and walks are enriched identically — the samples HealthKit holds against a
    /// workout do not depend on what the workout was — so the two differ only in the
    /// floor they must clear and the type they land with, which is exactly what this
    /// carries. Anything more than that belongs in the shared path, not in a branch.
    enum ImportKind: Sendable {
        case run
        case walk
        /// A ride, swim or other cardio session (B8); see `readsFootSamples`.
        case crossTraining

        /// Whether a workout of this size is worth importing at all.
        func isImportable(distanceMeters: Double, durationSeconds: Double) -> Bool {
            switch self {
            case .run:
                return HealthKitRepository.isImportableWorkout(
                    distanceMeters: distanceMeters, durationSeconds: durationSeconds
                )
            case .walk:
                return RunEffortPolicy.isRealWalk(
                    distanceMeters: distanceMeters, durationSeconds: durationSeconds
                )
            case .crossTraining:
                return CrossTrainingImportPolicy.isRealSession(durationSeconds: durationSeconds)
            }
        }

        /// The type an imported workout lands with. A walk is never classified against
        /// the runner's training paces — it is a walk however briskly it was taken.
        func workoutType(
            distanceMeters: Double,
            durationSeconds: Double,
            paces: TrainingPaces?
        ) -> WorkoutType {
            switch self {
            case .run:
                return HealthKitRepository.inferWorkoutType(
                    distanceMeters: distanceMeters,
                    durationSeconds: durationSeconds,
                    paces: paces
                )
            case .walk:
                return .walk
            case .crossTraining:
                return .crossTraining
            }
        }
    }

    /// Fetches running workouts from HealthKit in the given range, converts each to a
    /// `RunWorkout` (with heart rate and elevation from associated HealthKit samples),
    /// and returns only those whose HK UUID is not already in `existingIDs`.
    @MainActor func fetchImportableWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>,
        context: WorkoutImportContext = .unknownRunner
    ) async throws -> [RunWorkout] {
        let hkWorkouts = try await fetchWorkouts(from: startDate, to: endDate)
        return await importWorkouts(
            hkWorkouts,
            kind: .run,
            existingIDs: existingIDs,
            context: context,
            label: "running"
        )
    }

    // MARK: - Walking workout import

    @MainActor func fetchImportableWalkingWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>,
        context: WorkoutImportContext = .unknownRunner
    ) async throws -> [RunWorkout] {
        let hkWorkouts = try await fetchWalkingWorkouts(from: startDate, to: endDate)
        return await importWorkouts(
            hkWorkouts,
            kind: .walk,
            existingIDs: existingIDs,
            context: context,
            label: "walking"
        )
    }

    /// Walking workouts only.
    ///
    /// Deliberately just `.walking`, not `.hiking` — a hike is its own activity with its
    /// own distance profile, and folding it in would put a six-hour day on a mountain in
    /// the history list labelled "Walk". Passive step tracking is not touched either:
    /// this is the workout type, so only sessions somebody actually started appear.
    private func fetchWalkingWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        try await fetchWorkouts(of: [.walking], from: startDate, to: endDate)
    }

    /// Workouts of any of `activityTypes` starting in the range, newest first.
    private func fetchWorkouts(
        of activityTypes: [HKWorkoutActivityType], from startDate: Date, to endDate: Date
    ) async throws -> [HKWorkout] {
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

    @MainActor func fetchImportableCrossTrainingWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>,
        context: WorkoutImportContext = .unknownRunner
    ) async throws -> [RunWorkout] {
        let types = CrossTrainingImportPolicy.activityTypes
        let hkWorkouts = try await fetchWorkouts(of: types, from: startDate, to: endDate)
        return await importWorkouts(
            hkWorkouts, kind: .crossTraining, existingIDs: existingIDs, context: context, label: "cross-training"
        )
    }

    /// Converts fetched HealthKit workouts into `RunWorkout` models, skipping the ones
    /// already imported and the ones too small to be a session.
    ///
    /// One path for runs and walks: the samples HealthKit holds against a workout —
    /// heart rate, cadence, elevation, route, the distance series the splits are
    /// bucketed from — are the same either way, so only `kind` differs (the floor to
    /// clear, and the type to land with).
    @MainActor
    private func importWorkouts(
        _ hkWorkouts: [HKWorkout],
        kind: ImportKind,
        existingIDs: Set<String>,
        context: WorkoutImportContext,
        label: String
    ) async -> [RunWorkout] {
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
            if workoutDistanceMeters > 0 || !kind.readsFootSamples {
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
            guard kind.isImportable(distanceMeters: distanceMeters, durationSeconds: hkWorkout.duration) else {
                skippedTinyShell += 1
                continue
            }

            let hrStats = try? await fetchHeartRateStats(for: hkWorkout)
            let hrSamples = (try? await fetchHeartRateSamples(for: hkWorkout)) ?? []
            var cadence: Double?
            if kind.readsFootSamples {
                cadence = try? await fetchCadenceStepsPerMinute(for: hkWorkout)
            }
            let elevation = elevationGain(from: hkWorkout)
            let coordinates = await fetchRouteCoordinates(for: hkWorkout)

            // HealthKit's distance samples carry their own timestamps, so an imported
            // run can be bucketed into real splits instead of arriving with none (N9).
            var distancePoints: [SplitBucketing.DistancePoint] = []
            if kind.readsFootSamples {
                distancePoints = (try? await fetchDistanceSeries(for: hkWorkout)) ?? []
            }
            let splits = SplitBucketing.splits(
                from: distancePoints,
                splitLengthMeters: context.splitUnit.splitLengthMeters,
                heartRateSamples: hrSamples,
                totalDurationSeconds: hkWorkout.duration
            )

            let isIndoor = (hkWorkout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? false
            let run = RunWorkout(
                date: hkWorkout.startDate,
                distanceMeters: distanceMeters,
                durationSeconds: hkWorkout.duration,
                workoutType: kind.workoutType(
                    distanceMeters: distanceMeters,
                    durationSeconds: hkWorkout.duration,
                    paces: context.paces
                ),
                workoutLocation: isIndoor ? .indoor : .outdoor
            )
            run.averageHeartRate = hrStats?.avg
            run.maxHeartRate = hrStats?.max
            if !hrSamples.isEmpty { run.heartRateSamples = hrSamples }
            run.averageCadenceStepsPerMinute = cadence
            run.elevationGainMeters = elevation
            run.healthKitWorkoutID = hkID
            if !coordinates.isEmpty { run.routeCoordinates = coordinates }
            // Kept alongside the splits, not just used to build them: a one-mile import has
            // a single whole-mile split and needs the readings behind it for the summary's
            // charts to draw anything but one marker (N34).
            if !distancePoints.isEmpty { run.distanceSeries = distancePoints }
            if !splits.isEmpty {
                run.splits = splits
                run.splitUnit = context.splitUnit
            }
            result.append(run)
        }
        AppLogger.log(
            "HealthKit \(label) import candidates: fetched=\(hkWorkouts.count), importable=\(result.count), existing=\(skippedExisting), tooSmall=\(skippedTinyShell)",
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

    /// The workout's distance readings as a cumulative series, in workout-relative
    /// seconds. Each `HKQuantitySample` covers an interval and carries its own
    /// timestamps, which is what lets an imported run be bucketed into splits (N9);
    /// the cumulative sum is taken at each sample's end, where its distance is complete.
    private func fetchDistanceSeries(for workout: HKWorkout) async throws -> [SplitBucketing.DistancePoint] {
        let distanceType = HKQuantityType(.distanceWalkingRunning)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: workout),
            HKQuery.predicateForSamples(
                withStart: workout.startDate,
                end: workout.endDate,
                options: [.strictStartDate, .strictEndDate]
            )
        ])
        let samples: [HKSample] = try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: distanceType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, result, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: result ?? []) }
            }
            store.execute(query)
        }
        var cumulativeMeters: Double = 0
        return samples.compactMap { sample in
            guard let quantity = (sample as? HKQuantitySample)?.quantity else { return nil }
            cumulativeMeters += quantity.doubleValue(for: .meter())
            return SplitBucketing.DistancePoint(
                elapsedSeconds: sample.endDate.timeIntervalSince(workout.startDate),
                cumulativeMeters: cumulativeMeters
            )
        }
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

    /// Mean cadence for a workout in steps per minute, from the step count HealthKit
    /// recorded against it (A5).
    ///
    /// There is no `cadence` quantity type for running the way there is for cycling, so
    /// the figure is derived: total steps ÷ the workout's duration in minutes. That is the
    /// same definition `CMPedometer.currentCadence` reports for the app's own runs, which
    /// is what makes an imported cadence comparable with a recorded one.
    ///
    /// Scoped to the samples *associated with the workout* rather than merely overlapping
    /// its window, like the heart-rate queries — a time-only predicate would fold in the
    /// iPhone's own step count for a run recorded on a Watch and roughly double it.
    /// Returns `nil` when the source recorded no steps, which is normal for a treadmill
    /// import or a workout written by an app that only stored distance.
    private func fetchCadenceStepsPerMinute(for workout: HKWorkout) async throws -> Double? {
        guard workout.duration > 0 else { return nil }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: workout),
            HKQuery.predicateForSamples(
                withStart: workout.startDate, end: workout.endDate, options: .strictStartDate
            )
        ])
        let stats: HKStatistics? = try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsQuery(
                quantityType: HKQuantityType(.stepCount),
                quantitySamplePredicate: predicate,
                options: [.cumulativeSum]
            ) { _, result, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: result) }
            }
            store.execute(query)
        }
        guard let steps = stats?.sumQuantity()?.doubleValue(for: .count()), steps > 0 else { return nil }
        return steps / (workout.duration / 60)
    }

    /// Raw heart-rate bpm samples for a workout, in chronological order, scoped to the
    /// samples associated with the workout (like the HR-stats query).
    private func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [Double] {
        let hrType = HKQuantityType(.heartRate)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: workout),
            HKQuery.predicateForSamples(
                withStart: workout.startDate, end: workout.endDate, options: .strictStartDate
            )
        ])
        let bpmUnit = HKUnit(from: "count/min")
        let samples: [HKSample] = try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, result, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: result ?? []) }
            }
            store.execute(query)
        }
        return samples.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: bpmUnit) }
    }

    func fetchHeartRateSamples(forWorkoutID id: String) async -> [Double] {
        guard let workout = await hkWorkout(withID: id) else { return [] }
        return (try? await fetchHeartRateSamples(for: workout)) ?? []
    }

    func fetchDistanceSeries(forWorkoutID id: String) async -> [SplitBucketing.DistancePoint] {
        guard let workout = await hkWorkout(withID: id) else { return [] }
        return (try? await fetchDistanceSeries(for: workout)) ?? []
    }

    func fetchLatestBodyMassKilograms() async -> Double? {
        guard isAvailable else { return nil }
        let type = HKQuantityType(.bodyMass)

        let sample: HKQuantitySample? = try? await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, result, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: result?.first as? HKQuantitySample) }
            }
            store.execute(query)
        }

        // Kilograms regardless of how Health displays it: the unit here is the storage
        // unit, and the coach's rates are all per kilogram. Converting at the boundary
        // means nothing downstream has to know a pound exists.
        return sample?.quantity.doubleValue(for: .gramUnit(with: .kilo))
    }

    /// Resolves a stored HealthKit UUID string back to its workout, so samples can be
    /// re-read for a run that is already in the store. Returns `nil` once the source
    /// workout is gone (deleted in Health, or written by an app that has been removed).
    private func hkWorkout(withID id: String) async -> HKWorkout? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return try? await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: HKQuery.predicateForObject(with: uuid),
                limit: 1,
                sortDescriptors: nil
            ) { _, result, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: (result as? [HKWorkout])?.first) }
            }
            store.execute(query)
        }
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

    /// Infers a broad workout type from a run's distance and average pace.
    ///
    /// Apple Health has no concept of Easy/Tempo/LongRun, so this approximates — but
    /// relative to the runner's own training paces rather than one absolute threshold
    /// (N10). The old rule (`< 5:20/km ⇒ tempo`) was runner-independent and fed
    /// decisions that matter: `ProgressStatsService.estimatedVDOT` only samples
    /// quality sessions, and `RunSummaryView.tempoInsights` only renders for `.tempo`.
    /// A sub-20 5K runner had every easy run labelled "Tempo", inflating the VO₂-max
    /// trend with easy efforts, while a 6:00/km beginner never produced a quality
    /// session at all, so their estimated VO₂-max chart stayed empty no matter how
    /// much they ran.
    ///
    /// Marathon pace is the boundary between a quality effort and an easy run: it sits
    /// well clear of the top of the easy band, and a recorded tempo session includes
    /// its warm-up and cool-down, so its average lands slower than the prescribed
    /// threshold pace. With no pace estimate for the runner there is nothing to
    /// classify against, so a run is `.easy` unless its distance makes it a long run.
    /// Intervals are not inferred: distinguishing them needs the workout's structure
    /// (HealthKit events / lap markers), not an average.
    static func inferWorkoutType(
        distanceMeters: Double,
        durationSeconds: Double,
        paces: TrainingPaces?
    ) -> WorkoutType {
        if distanceMeters / 1_000 >= 16 { return .longRun }
        guard let paces, distanceMeters > 0, durationSeconds > 0 else { return .easy }
        let paceSecPerKm = durationSeconds / distanceMeters * 1_000
        return paceSecPerKm <= paces.marathon ? .tempo : .easy
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
