import Foundation
import HealthKit
import SwiftData
import Testing
@testable import Stride

// MARK: - Test doubles

/// Suspends callers until opened; used to hold a mock call in flight so tests
/// can interleave a second call deterministically.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let toResume = waiters
        waiters.removeAll()
        lock.unlock()
        toResume.forEach { $0.resume() }
    }
}

final class MockHealthKitRepository: HealthKitRepositoryProtocol, @unchecked Sendable {
    let isAvailable = true
    let isAuthorized = true

    // Run-fetch state is MainActor-confined: the protocol marks the fetches
    // @MainActor and the tests read these from MainActor.
    @MainActor var runFetchGate: AsyncGate?
    @MainActor var runFetchResults: [[RunWorkout]] = []
    @MainActor private(set) var runFetchCalls = 0
    /// The runner context the service passed to the last import (N9/N10).
    @MainActor private(set) var lastImportContext: WorkoutImportContext?
    @MainActor private(set) var registerCalls = 0
    @MainActor private(set) var observerHandler: (@Sendable (_ completion: @escaping @Sendable () -> Void) -> Void)?

    // enableBackgroundDelivery is nonisolated in the protocol, so its counter
    // needs its own lock.
    var enableGate: AsyncGate?
    private let lock = NSLock()
    private var _enableCalls = 0
    var enableCalls: Int { lock.withLock { _enableCalls } }

    func requestAuthorization() async throws {}

    @MainActor func save(_ workout: RunWorkout) async throws -> String { UUID().uuidString }

    /// Records the strength sessions exported to HealthKit (N14).
    @MainActor private(set) var savedStrengthWorkouts: [StrengthWorkout] = []
    @MainActor var strengthSaveError: Error?

    @MainActor func save(_ workout: StrengthWorkout) async throws -> String {
        if let strengthSaveError { throw strengthSaveError }
        savedStrengthWorkouts.append(workout)
        return UUID().uuidString
    }

    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] { [] }

    @MainActor func syncWorkoutPlans(for plan: TrainingPlan, unitPreference: UnitPreference) async throws {}

    @MainActor func removeWorkoutPlans(for plan: TrainingPlan) async throws {}

    @MainActor
    func fetchImportableWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>,
        context: WorkoutImportContext
    ) async throws -> [RunWorkout] {
        runFetchCalls += 1
        lastImportContext = context
        if let gate = runFetchGate { await gate.wait() }
        guard !runFetchResults.isEmpty else { return [] }
        return runFetchResults.removeFirst()
    }

    @MainActor
    func fetchImportableStrengthWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>
    ) async throws -> [StrengthWorkout] { [] }

    func fetchHeartRateSamples(forWorkoutID id: String) async -> [Double] { [] }

    func enableBackgroundDelivery() async throws {
        lock.withLock { _enableCalls += 1 }
        if let gate = enableGate { await gate.wait() }
    }

    func registerObserverQuery(
        handler: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void
    ) {
        // Called from WorkoutSyncService.startObserving, which is MainActor.
        MainActor.assumeIsolated {
            registerCalls += 1
            observerHandler = handler
        }
    }
}

// MARK: - Tests

@MainActor
struct WorkoutSyncServiceTests {

    private func makeService(mock: MockHealthKitRepository) -> (WorkoutSyncService, ModelContext) {
        let container = AppContainer.preview()
        let context = container.modelContainer.mainContext
        let service = WorkoutSyncService(
            healthKitRepository: mock,
            notificationService: NotificationService.shared,
            weatherService: WeatherService(),
            context: context
        )
        return (service, context)
    }

    private func waitUntil(
        timeoutSeconds: Double = 5,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    /// M2: `isObserving` used to be set only after the `enableBackgroundDelivery`
    /// await, so two concurrent `startObserving` calls (StrideApp.task + the
    /// restore flow) both saw "not observing" and registered duplicate observer
    /// queries — every HealthKit change then triggered two sync passes.
    @Test("Concurrent startObserving registers exactly one observer query (M2)")
    func startObservingRegistersOnce() async {
        let mock = MockHealthKitRepository()
        let gate = AsyncGate()
        mock.enableGate = gate
        let (service, _) = makeService(mock: mock)

        // First call suspends inside enableBackgroundDelivery.
        let first = Task { await service.startObserving() }
        #expect(await waitUntil { mock.enableCalls == 1 })

        // Second call arrives while the first is still suspended; it must not
        // register (or enable) a second time, and completes independently.
        await service.startObserving()

        gate.open()
        _ = await first.value

        #expect(mock.enableCalls == 1)
        #expect(mock.registerCalls == 1)
    }

    /// M1: an observer trigger that lands while a sync pass is in flight used to
    /// be consumed by the `isSyncing` guard with no follow-up — a Watch sync
    /// burst left the second workout unimported until the next app launch.
    @Test("An observer trigger arriving mid-sync is queued and replayed (M1)")
    func observerTriggerQueuedDuringSync() async throws {
        let mock = MockHealthKitRepository()
        let gate = AsyncGate()
        let (service, context) = makeService(mock: mock)

        mock.runFetchGate = gate
        // Startup pass finds nothing; the replayed observer pass finds the new run.
        let newRun = RunWorkout(
            date: Date(),
            distanceMeters: 8_000,
            durationSeconds: 2_400,
            workoutType: .easy
        )
        newRun.healthKitWorkoutID = UUID().uuidString
        mock.runFetchResults = [[], [newRun]]

        // Startup sync suspends inside its run fetch.
        let startup = Task { await service.startObserving() }
        #expect(await waitUntil { mock.runFetchCalls == 1 })

        // HealthKit's observer fires while that sync is still in flight.
        await confirmation("observer completion is called") { confirm in
            mock.observerHandler?({ confirm() })
            // The trigger must be queued, not dropped.
            #expect(await waitUntil { service.pendingSyncSource != nil })

            gate.open()
            _ = await startup.value
        }

        // The queued pass ran after the startup pass and imported the run.
        #expect(mock.runFetchCalls == 2)
        #expect(service.pendingSyncSource == nil)
        let stored = try context.fetch(FetchDescriptor<RunWorkout>())
        #expect(stored.count == 1)
        #expect(stored.first?.healthKitWorkoutID == newRun.healthKitWorkoutID)

        UserDefaults.standard.removeObject(forKey: "pendingReviewWorkoutID")
    }

    // MARK: On-demand sync + linking (N4)

    /// Builds an active (or retired) plan with a single uncompleted run scheduled today.
    private func makePlanWithTodaysRun(in context: ModelContext, isActive: Bool) throws -> ScheduledWorkout {
        let today = Date().startOfDay
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: today,
            endDate: today.adding(days: 6)
        )
        plan.isActive = isActive
        context.insert(plan)

        let week = TrainingWeek(weekNumber: 1, startDate: today, phase: .base, targetDistanceKm: 20)
        context.insert(week)
        week.plan = plan

        let scheduled = ScheduledWorkout(
            scheduledDate: today,
            workoutType: .easy,
            targetDistanceMeters: 5_000
        )
        context.insert(scheduled)
        scheduled.week = week

        try context.save()
        return scheduled
    }

    /// N4: `HistoryView` used to import on its own and never link, so a run the user
    /// had actually done left its planned day showing as missed — and because that
    /// import usually ran first, the canonical pass then skipped the run as existing.
    @Test("syncNow imports through the canonical path and links the run to its planned day (N4)")
    func syncNowLinksImportedRunToPlan() async throws {
        let mock = MockHealthKitRepository()
        let (service, context) = makeService(mock: mock)
        let scheduled = try makePlanWithTodaysRun(in: context, isActive: true)

        let run = RunWorkout(
            date: Date(),
            distanceMeters: 5_000,
            durationSeconds: 1_500,
            workoutType: .easy
        )
        run.healthKitWorkoutID = UUID().uuidString
        mock.runFetchResults = [[run]]

        await service.syncNow(lookbackDays: 60, source: "test")

        #expect(scheduled.isCompleted == true)
        #expect(scheduled.completedWorkout?.id == run.id)
        #expect(run.scheduledWorkout?.id == scheduled.id)

        UserDefaults.standard.removeObject(forKey: "pendingReviewWorkoutID")
    }

    /// N1/N2 keep retired plans in the store, so their future days must stop
    /// attracting imported runs.
    @Test("An imported run never completes a retired plan's day")
    func syncNowIgnoresRetiredPlanDays() async throws {
        let mock = MockHealthKitRepository()
        let (service, context) = makeService(mock: mock)
        let retiredDay = try makePlanWithTodaysRun(in: context, isActive: false)

        let run = RunWorkout(
            date: Date(),
            distanceMeters: 5_000,
            durationSeconds: 1_500,
            workoutType: .easy
        )
        run.healthKitWorkoutID = UUID().uuidString
        mock.runFetchResults = [[run]]

        await service.syncNow(source: "test")

        #expect(retiredDay.isCompleted == false)
        #expect(retiredDay.completedWorkout == nil)
        // The run itself still imports — it just isn't credited to a retired plan.
        let stored = try context.fetch(FetchDescriptor<RunWorkout>())
        #expect(stored.contains { $0.healthKitWorkoutID == run.healthKitWorkoutID })

        UserDefaults.standard.removeObject(forKey: "pendingReviewWorkoutID")
    }

    // MARK: Runner context handed to the importer (N9/N10)

    private func insertProfile(
        in context: ModelContext,
        estimated5KSeconds: Double?
    ) throws {
        let profile = UserProfile(
            name: "Test",
            goalRace: .fiveK,
            goalFinishTime: 1_500,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate,
            currentEstimated5KTimeSeconds: estimated5KSeconds
        )
        context.insert(profile)
        try context.save()
    }

    /// N10: the importer classifies a run's type against the runner's own training
    /// paces, so the sync pass has to resolve them from the store — otherwise every
    /// import falls back to "no idea who this runner is".
    @Test("The sync pass hands the runner's own paces to the importer (N10)")
    func syncResolvesRunnerPaces() async throws {
        let mock = MockHealthKitRepository()
        let (service, context) = makeService(mock: mock)
        try insertProfile(in: context, estimated5KSeconds: 1_200)
        mock.runFetchResults = [[]]

        await service.syncNow(source: "test")

        let expected = PaceCalculatorService.trainingPaces(from5KTimeSeconds: 1_200)
        #expect(mock.lastImportContext?.paces?.marathon == expected.marathon)
        #expect(mock.lastImportContext?.paces?.threshold == expected.threshold)
    }

    @Test("With no 5 K estimate the importer is given nothing to classify against")
    func syncWithoutEstimateSendsNoPaces() async throws {
        let mock = MockHealthKitRepository()
        let (service, context) = makeService(mock: mock)
        try insertProfile(in: context, estimated5KSeconds: nil)
        mock.runFetchResults = [[]]

        await service.syncNow(source: "test")

        #expect(mock.lastImportContext != nil)
        #expect(mock.lastImportContext?.paces == nil)
    }

    // MARK: Notification batching (M5)

    @Test("Imports collapse to one summary notification only above the per-run banner limit (M5)")
    func batchThreshold() {
        #expect(!WorkoutSyncService.shouldBatchSyncNotifications(count: 1))
        #expect(!WorkoutSyncService.shouldBatchSyncNotifications(
            count: WorkoutSyncService.maxIndividualSyncNotifications
        ))
        #expect(WorkoutSyncService.shouldBatchSyncNotifications(
            count: WorkoutSyncService.maxIndividualSyncNotifications + 1
        ))
        // A fresh-install 90-day recovery must never fire dozens of banners.
        #expect(WorkoutSyncService.shouldBatchSyncNotifications(count: 50))
    }
}
