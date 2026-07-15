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

    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] { [] }

    @MainActor func syncWorkoutPlans(for plan: TrainingPlan, unitPreference: UnitPreference) async throws {}

    @MainActor func removeWorkoutPlans(for plan: TrainingPlan) async throws {}

    @MainActor
    func fetchImportableWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>
    ) async throws -> [RunWorkout] {
        runFetchCalls += 1
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
