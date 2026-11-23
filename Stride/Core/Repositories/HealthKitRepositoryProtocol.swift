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
    /// Re-schedules one workout's WorkoutKit composition after its prescription changed,
    /// leaving the rest of the plan alone. Unlike ``syncWorkoutPlans(for:unitPreference:)``
    /// this never asks for authorization: it is an edit, not a first sync.
    @MainActor func syncWorkoutPlan(for workout: ScheduledWorkout, unitPreference: UnitPreference) async throws
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
    /// Fetches the GPS route for a previously-imported workout, identified by its
    /// HealthKit UUID string. Used to backfill a run imported before its route had synced
    /// from the Watch (see `RouteBackfill`). Returns `[]` if the workout has no route yet,
    /// or it can't be found.
    func fetchRouteCoordinates(forWorkoutID id: String) async -> [Coordinate]
    /// What Health knows about an imported strength workout: see `ImportedWorkoutDetails`.
    func fetchImportedWorkoutDetails(forWorkoutID id: String) async -> ImportedWorkoutDetails?
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
    /// The last `baselineDays` of daily HRV and resting heart rate, and last night's
    /// asleep time, for the readiness card (B7).
    ///
    /// Read-only, and like `fetchLatestBodyMassKilograms` silent on every failure path:
    /// a type that is denied, missing or empty contributes nothing, and the readiness
    /// score is built from whatever did come back. HealthKit reports "denied" and "no
    /// samples" identically for reads anyway.
    func fetchRecoveryReadings(endingAt now: Date, baselineDays: Int) async -> RecoveryReadings
    /// Enables HealthKit background delivery for running workouts at `.immediate` frequency.
    /// Safe to call multiple times — HealthKit is idempotent.
    func enableBackgroundDelivery() async throws
    /// Registers a long-lived observer query that calls `handler` whenever new running
    /// workouts are written to HealthKit. The handler is invoked on an arbitrary
    /// background queue; callers are responsible for hopping to the appropriate actor.
    func registerObserverQuery(handler: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void)
}
