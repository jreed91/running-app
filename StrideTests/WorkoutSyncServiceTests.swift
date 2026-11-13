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
    /// Explicit and `@MainActor` because the stored properties below are split across
    /// two isolations: the run-fetch state is MainActor-confined and its defaults are
    /// MainActor-isolated expressions, while `lock`/`_enableCalls` are nonisolated. The
    /// *implicit* memberwise initializer would have to be both at once, which Swift 6.3
    /// rejects outright ("cannot be both nonisolated and main actor-isolated"). Every
    /// suite that builds this mock is already `@MainActor`, so isolating the init costs
    /// nothing.
    @MainActor init() {}

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

    @MainActor func syncWorkoutPlan(for workout: ScheduledWorkout, unitPreference: UnitPreference) async throws {}

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

    /// Walks the mock hands back, newest pass first, mirroring `runFetchResults`.
    @MainActor var walkFetchResults: [[RunWorkout]] = []
    @MainActor private(set) var walkFetchCalls = 0

    @MainActor
    func fetchImportableWalkingWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>,
        context: WorkoutImportContext
    ) async throws -> [RunWorkout] {
        walkFetchCalls += 1
        guard !walkFetchResults.isEmpty else { return [] }
        return walkFetchResults.removeFirst()
    }

    /// Cross-training sessions the mock hands back, one entry per pass (B8).
    @MainActor var crossTrainingFetchResults: [[RunWorkout]] = []
    @MainActor private(set) var crossTrainingFetchCalls = 0

    @MainActor
    func fetchImportableCrossTrainingWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>,
        context: WorkoutImportContext
    ) async throws -> [RunWorkout] {
        crossTrainingFetchCalls += 1
        guard !crossTrainingFetchResults.isEmpty else { return [] }
        return crossTrainingFetchResults.removeFirst()
    }

    @MainActor
    func fetchImportableStrengthWorkouts(
        from startDate: Date,
        to endDate: Date,
        existingIDs: Set<String>
    ) async throws -> [StrengthWorkout] { [] }

    func fetchHeartRateSamples(forWorkoutID id: String) async -> [Double] { [] }

    func fetchDistanceSeries(forWorkoutID id: String) async -> [SplitBucketing.DistancePoint] { [] }

    func fetchRouteCoordinates(forWorkoutID id: String) async -> [Coordinate] { [] }

    /// Settable so a suite can stand in a weight; `nil` is the state a runner who has
    /// never recorded one lands in, which is what most of these tests want. A plain
    /// `var` like `enableGate` above — the class is already `@unchecked Sendable`.
    var bodyMassKilograms: Double?

    func fetchLatestBodyMassKilograms() async -> Double? { bodyMassKilograms }

    func fetchRecoveryReadings(endingAt now: Date, baselineDays: Int) async -> RecoveryReadings {
        RecoveryReadings()
    }

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
        // A bare context, not `TestStore.makeContainer()`: the service under test is
        // constructed here against mocks, so the app container's own copy of it — and the
        // thirteen other services beside it — were built and thrown away on every call.
        let context = TestStore.makeContext()
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

    // MARK: Stride's own exports (P1.3)

    /// The in-app run is saved before its HealthKit save returns an id, and writing the
    /// workout fires Stride's own observer. The importer hands that export back with the
    /// run's own `id` (its `StrideWorkoutID` metadata); it must link, not import.
    @Test("Stride's own HealthKit export links the stored run instead of importing a copy (P1.3)")
    func ownExportLinksInsteadOfImporting() async throws {
        let mock = MockHealthKitRepository()
        let (service, context) = makeService(mock: mock)

        let recorded = RunWorkout(
            date: Date(),
            distanceMeters: 8_000,
            durationSeconds: 2_400,
            workoutType: .easy
        )
        context.insert(recorded)
        try context.save()

        let export = RunWorkout(
            date: recorded.date,
            distanceMeters: 8_000,
            durationSeconds: 2_400,
            workoutType: .easy
        )
        export.id = recorded.id
        let exportHealthKitID = UUID().uuidString
        export.healthKitWorkoutID = exportHealthKitID
        mock.runFetchResults = [[export]]

        await service.syncNow(source: "test")

        let runs = try context.fetch(FetchDescriptor<RunWorkout>())
        #expect(runs.count == 1)
        #expect(runs.first?.id == recorded.id)
        #expect(runs.first?.healthKitWorkoutID == exportHealthKitID)
    }

    @Test("A run already linked keeps its HealthKit id and a second copy is dropped (P1.3)")
    func ownExportOfLinkedRunIsDropped() {
        let linked = RunWorkout(date: Date(), distanceMeters: 5_000, durationSeconds: 1_500, workoutType: .easy)
        linked.healthKitWorkoutID = "original"
        let copy = RunWorkout(date: linked.date, distanceMeters: 5_000, durationSeconds: 1_500, workoutType: .easy)
        copy.id = linked.id
        copy.healthKitWorkoutID = "second-copy"
        let other = RunWorkout(date: Date(), distanceMeters: 10_000, durationSeconds: 3_000, workoutType: .longRun)
        other.healthKitWorkoutID = "watch-run"

        let remaining = WorkoutSyncService.withoutOwnExports([copy, other], stored: [linked])

        #expect(remaining.map(\.id) == [other.id])
        #expect(linked.healthKitWorkoutID == "original")
    }

    // MARK: Same run recorded twice

    /// A free run on the phone with the Workout app also going on the Watch is two
    /// workouts in Health. The Watch's copy has its own UUID and no `StrideWorkoutID`, so
    /// it used to come in as a second run and complete the day's planned session.
    @Test("A Watch recording of a run Stride already has is skipped and tombstoned, and completes nothing")
    func sameTimeCopyIsSkipped() async throws {
        let mock = MockHealthKitRepository()
        let (service, context) = makeService(mock: mock)
        let scheduled = try makePlanWithTodaysRun(in: context, isActive: true)

        let start = Date().addingTimeInterval(-3_600)
        let freeRun = RunWorkout(date: start, distanceMeters: 5_000, durationSeconds: 1_800, workoutType: .easy)
        context.insert(freeRun)
        try context.save()

        // Started a minute later on the wrist, stopped a minute earlier.
        let watchCopy = RunWorkout(
            date: start.addingTimeInterval(60),
            distanceMeters: 4_800,
            durationSeconds: 1_680,
            workoutType: .tempo
        )
        let watchID = UUID().uuidString
        watchCopy.healthKitWorkoutID = watchID
        mock.runFetchResults = [[watchCopy]]

        await service.syncNow(source: "test")

        let runs = try context.fetch(FetchDescriptor<RunWorkout>())
        #expect(runs.map(\.id) == [freeRun.id])
        #expect(scheduled.isCompleted == false)
        let tombstones = try context.fetch(FetchDescriptor<DeletedWorkout>())
        #expect(tombstones.map(\.healthKitWorkoutID) == [watchID])

        UserDefaults.standard.removeObject(forKey: "pendingReviewWorkoutID")
    }

    @Test("Runs that share most of their time are one run; back-to-back runs are two")
    func sameRecordingOverlap() {
        let start = Date()
        func run(_ offset: TimeInterval, _ duration: TimeInterval) -> RunWorkout {
            RunWorkout(
                date: start.addingTimeInterval(offset),
                distanceMeters: 5_000,
                durationSeconds: duration,
                workoutType: .easy
            )
        }
        let phone = run(0, 1_800)

        #expect(WorkoutSyncService.isSameRecording(phone, run(60, 1_680)))
        // Watch stopped half way: still the same run.
        #expect(WorkoutSyncService.isSameRecording(phone, run(0, 900)))
        // A cool-down jog straight after: touches but does not overlap.
        #expect(!WorkoutSyncService.isSameRecording(phone, run(1_800, 600)))
        // A second run that morning that only clips the first's last few minutes.
        #expect(!WorkoutSyncService.isSameRecording(phone, run(1_500, 1_800)))
        #expect(!WorkoutSyncService.isSameRecording(phone, run(7_200, 1_800)))
    }

    @Test("A walk at the same time as an imported run does not swallow it")
    func storedWalkDoesNotDropRun() {
        let start = Date()
        let walk = RunWorkout(date: start, distanceMeters: 3_000, durationSeconds: 1_800, workoutType: .walk)
        let run = RunWorkout(date: start, distanceMeters: 5_000, durationSeconds: 1_800, workoutType: .easy)

        let (kept, copies) = WorkoutSyncService.splittingSameTimeCopies([run], stored: [walk])

        #expect(kept.map(\.id) == [run.id])
        #expect(copies.isEmpty)
    }

    @Test("Only a valid StrideWorkoutID in a workout's metadata names a Stride run (P1.3)")
    func strideWorkoutIDMetadata() {
        let key = HealthKitRepository.strideWorkoutIDMetadataKey
        let id = UUID()

        #expect(HealthKitRepository.strideWorkoutID(from: [key: id.uuidString]) == id)
        #expect(HealthKitRepository.strideWorkoutID(from: nil) == nil)
        #expect(HealthKitRepository.strideWorkoutID(from: [key: "not-a-uuid"]) == nil)
        #expect(HealthKitRepository.strideWorkoutID(from: ["SomeOtherKey": id.uuidString]) == nil)
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
