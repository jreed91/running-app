import Foundation
import HealthKit
import CoreLocation
import WorkoutKit

// MARK: - Protocol

protocol HealthKitRepositoryProtocol: Sendable {
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    @MainActor func save(_ workout: RunWorkout) async throws -> String
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout]
    /// Schedules each non-rest future workout in the plan as a WorkoutKit composition
    /// so it appears in the Apple Watch Workout app and the Fitness app.
    @MainActor func syncWorkoutPlans(for plan: TrainingPlan) async throws
    /// Removes all WorkoutKit scheduled compositions for the plan.
    @MainActor func removeWorkoutPlans(for plan: TrainingPlan) async throws
    /// Fetches running workouts from HealthKit, converts them to RunWorkout models,
    /// and skips any whose HK UUID is already in `existingIDs`.
    @MainActor func fetchImportableWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>
    ) async throws -> [RunWorkout]
}

// MARK: - Live implementation

final class HealthKitRepository: HealthKitRepositoryProtocol, @unchecked Sendable {
    private let store = HKHealthStore()

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

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(
            toShare: Self.shareTypes,
            read: Self.readTypes
        )
    }

    // MARK: - Completed workout

    @MainActor func save(_ workout: RunWorkout) async throws -> String {
        let hkWorkout = HKWorkout(
            activityType: .running,
            start: workout.date,
            end: workout.date.addingTimeInterval(workout.durationSeconds),
            duration: workout.durationSeconds,
            totalEnergyBurned: nil,
            totalDistance: HKQuantity(unit: .meter(), doubleValue: workout.distanceMeters),
            metadata: ["RunningAppWorkoutID": workout.id.uuidString]
        )
        try await store.save(hkWorkout)
        return hkWorkout.uuid.uuidString
    }

    // MARK: - Workout plans (WorkoutKit)

    @MainActor func syncWorkoutPlans(for plan: TrainingPlan) async throws {
        guard WorkoutScheduler.isSupported else { return }
        let scheduler = WorkoutScheduler.shared

        if scheduler.authorizationState == .notDetermined {
            let state = await scheduler.requestAuthorization()
            guard state == .authorized else { return }
        }
        guard scheduler.authorizationState == .authorized else { return }

        let now = Date()
        for week in plan.weeks {
            for workout in week.workouts
            where workout.workoutType != .rest
               && !workout.isCompleted
               && workout.scheduledDate > now
               && workout.healthKitPlanID == nil
            {
                let workoutPlan = makeWorkoutPlan(for: workout)
                let dateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: workout.scheduledDate
                )
                await scheduler.schedule(workoutPlan, at: dateComponents)
                workout.healthKitPlanID = workoutPlan.id.uuidString
            }
        }
    }

    @MainActor func removeWorkoutPlans(for plan: TrainingPlan) async throws {
        let allWorkouts = plan.weeks.flatMap(\.workouts)
        defer { allWorkouts.forEach { $0.healthKitPlanID = nil } }

        guard WorkoutScheduler.isSupported else { return }
        let scheduler = WorkoutScheduler.shared
        guard scheduler.authorizationState == .authorized else { return }

        let ids = Set(allWorkouts.compactMap(\.healthKitPlanID))
        guard !ids.isEmpty else { return }

        for entry in scheduler.scheduledWorkouts where ids.contains(entry.plan.id.uuidString) {
            await scheduler.remove(entry.plan, at: entry.date)
        }
    }

    // MARK: - WorkoutKit plan builder

    private func makeWorkoutPlan(for workout: ScheduledWorkout) -> WorkoutPlan {
        let warmup = WorkoutStep(goal: .open, alert: nil)
        let cooldown = WorkoutStep(goal: .open, alert: nil)
        let blocks: [IntervalBlock]

        if workout.workoutType == .interval && !workout.intervals.isEmpty {
            blocks = workout.intervals.map { interval in
                let workGoal: WorkoutGoal
                if let distance = interval.distanceMeters {
                    workGoal = .distance(distance, UnitLength.meters)
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
                .map { .distance($0, UnitLength.meters) } ?? .open
            let workStep = IntervalStep(.work, goal: goal, alert: nil)
            blocks = [IntervalBlock(steps: [workStep], iterations: 1)]
        }

        let customWorkout = CustomWorkout(
            activity: .running,
            location: .outdoor,
            displayName: workout.workoutType.displayName,
            warmup: warmup,
            blocks: blocks,
            cooldown: cooldown
        )
        return WorkoutPlan(.custom(customWorkout), id: UUID())
    }

    // MARK: - Historical workout fetch

    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        let runningPredicate = HKQuery.predicateForWorkouts(with: .running)
        let datePredicate = HKQuery.predicateForSamples(
            withStart: startDate, end: endDate, options: .strictStartDate
        )
        let compound = NSCompoundPredicate(
            andPredicateWithSubpredicates: [runningPredicate, datePredicate]
        )
        return try await withCheckedThrowingContinuation { continuation in
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
    }

    // MARK: - Import workouts from HealthKit

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

        for hkWorkout in hkWorkouts {
            let hkID = hkWorkout.uuid.uuidString
            guard !existingIDs.contains(hkID) else { continue }

            let distanceMeters = hkWorkout.totalDistance?.doubleValue(for: .meter()) ?? 0
            guard distanceMeters > 100 else { continue }

            let hrStats = try? await fetchHeartRateStats(for: hkWorkout)
            let elevation = elevationGain(from: hkWorkout)
            let coordinates = await fetchRouteCoordinates(for: hkWorkout)

            let run = RunWorkout(
                date: hkWorkout.startDate,
                distanceMeters: distanceMeters,
                durationSeconds: hkWorkout.duration,
                workoutType: inferWorkoutType(distanceMeters: distanceMeters, durationSeconds: hkWorkout.duration)
            )
            run.averageHeartRate = hrStats?.avg
            run.maxHeartRate = hrStats?.max
            run.elevationGainMeters = elevation
            run.healthKitWorkoutID = hkID
            if !coordinates.isEmpty { run.routeCoordinates = coordinates }
            result.append(run)
        }
        return result
    }

    // MARK: - HealthKit sample helpers

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

        guard let route = routes.first else { return [] }

        // Step 2: stream CLLocation objects from the route
        var coordinates: [Coordinate] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let routeQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, _ in
                if let locations {
                    coordinates += locations.map { Coordinate($0.coordinate) }
                }
                if done { continuation.resume() }
            }
            store.execute(routeQuery)
        }

        return coordinates
    }

    private func fetchHeartRateStats(for workout: HKWorkout) async throws -> (avg: Double?, max: Double?) {
        let hrType = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate, end: workout.endDate, options: .strictStartDate
        )
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
}
