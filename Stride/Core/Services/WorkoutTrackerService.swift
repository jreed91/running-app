import Foundation
import CoreLocation
import CoreMotion
import Combine
import HealthKit

// MARK: - Tracking state

enum TrackingState: Equatable, Sendable {
    case idle
    case active
    case paused
    case finished
}

// MARK: - WorkoutTrackerService

/// Manages a live run session, supporting both outdoor (GPS) and indoor (pedometer) modes.
///
/// Call order:
///  1. `setLocation(_:)` — optional, defaults to `.outdoor`
///  2. `startWorkout(type:)`
///  3. `pauseWorkout()` / `resumeWorkout()` as needed
///  4. `finishWorkout()` → returns the completed `RunWorkout`
@MainActor
final class WorkoutTrackerService: NSObject, ObservableObject {

    // MARK: Published state

    @Published private(set) var trackingState: TrackingState = .idle
    @Published private(set) var workoutLocation: WorkoutLocation = .outdoor
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var distanceMeters: Double = 0
    @Published private(set) var currentPaceSecondsPerKm: Double = 0
    @Published private(set) var currentHeartRate: Double?
    @Published private(set) var coordinates: [Coordinate] = []
    @Published private(set) var splits: [Split] = []

    // MARK: Private

    private var workoutType: WorkoutType = .easy
    private var startDate = Date()
    private var timer: Timer?
    private var lastLocation: CLLocation?
    private var lastSplitDistance: Double = 0

    /// Distance unit splits are bucketed in, captured at `startWorkout` from the user's
    /// preference so an imperial runner gets genuine per-mile splits rather than km
    /// buckets relabelled "mi" (A1). `splitLengthMeters` is the derived bucket size.
    private var splitUnit: UnitPreference = .metric
    private var splitLengthMeters: Double = UnitPreference.metric.splitLengthMeters

    /// Wall-clock elapsed time, immune to process suspension / stalled run loops (M23).
    private var stopwatch = WallClockStopwatch()

    /// Elevation gain accumulated across the whole run and the current split bucket.
    /// (M26 — a split's gain is the sum of positive altitude deltas within the km,
    /// not just the delta between its final two GPS fixes.)
    private var totalElevationGainMeters: Double = 0
    private var currentSplitElevationGainMeters: Double = 0

    /// Distance banked from active segments before the current indoor resume, so
    /// resuming the pedometer from "now" no longer replays distance walked while
    /// paused (M24). The pedometer reports cumulative distance since its own start
    /// date, so each active segment is measured independently and summed here.
    private var indoorDistanceBaselineMeters: Double = 0

    private let locationManager = CLLocationManager()
    private let autoPauseThresholdMetersPerSecond: Double = 0.5  // below this ≈ standing still

    private let hkStore = HKHealthStore()
    private var hrQuery: HKAnchoredObjectQuery?
    private var hrSamples: [Double] = []

    private let pedometer = CMPedometer()
    private var pedometerActive = false

    // MARK: Public API

    /// Set the workout location before calling `startWorkout`. No-op once a workout is active.
    func setLocation(_ location: WorkoutLocation) {
        guard trackingState == .idle else { return }
        workoutLocation = location
    }

    func startWorkout(type: WorkoutType, distanceUnit: UnitPreference = .metric) {
        guard trackingState == .idle else { return }
        workoutType = type
        splitUnit = distanceUnit
        splitLengthMeters = distanceUnit.splitLengthMeters
        startDate = Date()
        reset()
        trackingState = .active
        stopwatch.start(at: startDate)
        startTimer()
        startHeartRateQuery(from: startDate)

        if workoutLocation == .outdoor {
            configureLocationManager()
            locationManager.startUpdatingLocation()
        } else {
            startPedometerUpdates(from: startDate)
        }
    }

    func pauseWorkout() {
        guard trackingState == .active else { return }
        trackingState = .paused
        stopwatch.pause(at: Date())
        elapsedSeconds = stopwatch.accumulated
        timer?.invalidate()
        if workoutLocation == .outdoor {
            locationManager.stopUpdatingLocation()
        } else {
            // Bank distance covered so far; the next pedometer segment starts fresh
            // from its own resume date so paused walking is not replayed (M24).
            indoorDistanceBaselineMeters = distanceMeters
            stopPedometerUpdates()
        }
        if let q = hrQuery { hkStore.stop(q) }
    }

    func resumeWorkout() {
        guard trackingState == .paused else { return }
        trackingState = .active
        stopwatch.resume(at: Date())
        startTimer()
        startHeartRateQuery(from: Date())
        if workoutLocation == .outdoor {
            locationManager.startUpdatingLocation()
        } else {
            startPedometerUpdates(from: Date())
        }
    }

    /// Returns the tracker to `.idle` after a finished workout so a new one can start.
    /// The service is a single long-lived instance, so without this transition
    /// `startWorkout` would silently no-op for every run after the first.
    /// No-op while a workout is active or paused.
    func prepareForNewWorkout() {
        guard trackingState == .finished else { return }
        reset()
        trackingState = .idle
    }

    func finishWorkout() -> RunWorkout? {
        guard trackingState == .active || trackingState == .paused else { return nil }
        timer?.invalidate()
        if workoutLocation == .outdoor {
            locationManager.stopUpdatingLocation()
        } else {
            stopPedometerUpdates()
        }
        if let q = hrQuery { hkStore.stop(q); hrQuery = nil }
        stopwatch.pause(at: Date())
        elapsedSeconds = stopwatch.accumulated
        trackingState = .finished

        let workout = RunWorkout(
            date: startDate,
            distanceMeters: distanceMeters,
            durationSeconds: elapsedSeconds,
            workoutType: workoutType,
            workoutLocation: workoutLocation
        )
        workout.routeCoordinates = coordinates
        workout.splits = splits
        workout.splitUnit = splitUnit
        if totalElevationGainMeters > 0 {
            workout.elevationGainMeters = totalElevationGainMeters
        }
        if !hrSamples.isEmpty {
            workout.averageHeartRate = hrSamples.reduce(0, +) / Double(hrSamples.count)
            workout.maxHeartRate = hrSamples.max()
            // Persist the raw series (previously discarded) so the time-in-zone
            // breakdown can be computed for app-recorded runs (A6).
            workout.heartRateSamples = hrSamples
        }
        return workout
    }

    // MARK: Private helpers

    private func reset() {
        stopwatch.reset()
        elapsedSeconds = 0
        distanceMeters = 0
        currentPaceSecondsPerKm = 0
        currentHeartRate = nil
        coordinates = []
        splits = []
        hrSamples = []
        lastLocation = nil
        lastSplitDistance = 0
        totalElevationGainMeters = 0
        currentSplitElevationGainMeters = 0
        indoorDistanceBaselineMeters = 0
        pedometerActive = false
    }

    // MARK: - Pedometer (indoor)

    private func startPedometerUpdates(from segmentStart: Date) {
        guard CMPedometer.isDistanceAvailable(), !pedometerActive else { return }
        pedometerActive = true
        let baseline = indoorDistanceBaselineMeters
        pedometer.startUpdates(from: segmentStart) { [weak self] data, error in
            guard let data, error == nil else { return }
            // `distance` is cumulative since `segmentStart`; add the distance banked
            // before this segment so a pause/resume never replays or drops meters (M24).
            let meters = baseline + (data.distance?.doubleValue ?? 0)
            Task { @MainActor [weak self] in
                guard let self, self.trackingState == .active else { return }
                self.distanceMeters = meters
                // Guard the divisor, not the elapsed time (M25) — otherwise the first
                // callbacks (meters == 0) produce a +inf pace.
                if meters > 0 {
                    self.currentPaceSecondsPerKm = self.elapsedSeconds / meters * 1_000
                }
                self.updateSplitsForIndoor()
            }
        }
    }

    private func stopPedometerUpdates() {
        pedometer.stopUpdates()
        pedometerActive = false
    }

    private func updateSplitsForIndoor() {
        guard SplitBucketing.crossedBoundary(
            previousMeters: lastSplitDistance,
            currentMeters: distanceMeters,
            splitLengthMeters: splitLengthMeters
        ) else { return }
        let unitsCovered = SplitBucketing.bucketIndex(
            distanceMeters: distanceMeters, splitLengthMeters: splitLengthMeters
        )
        let split = Split(
            kilometer: unitsCovered,
            paceSecondsPerKm: currentPaceSecondsPerKm,
            heartRate: currentHeartRate,
            elevationGainMeters: 0,
            cumulativeDistanceMeters: distanceMeters
        )
        splits.append(split)
        lastSplitDistance = distanceMeters
    }

    // MARK: - Heart rate

    private func startHeartRateQuery(from startDate: Date) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let hrType = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictStartDate)
        let handler: @Sendable (
            HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, (any Error)?
        ) -> Void = { [weak self] _, newSamples, _, _, _ in
            self?.processHRSamples(newSamples)
        }
        let query = HKAnchoredObjectQuery(
            type: hrType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit,
            resultsHandler: handler
        )
        query.updateHandler = handler
        hrQuery = query
        hkStore.execute(query)
    }

    private nonisolated func processHRSamples(_ samples: [HKSample]?) {
        guard let samples, !samples.isEmpty else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let bpmValues: [Double] = samples.compactMap {
            ($0 as? HKQuantitySample)?.quantity.doubleValue(for: unit)
        }
        guard !bpmValues.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.hrSamples.append(contentsOf: bpmValues)
            self.currentHeartRate = bpmValues.last
        }
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.trackingState == .active else { return }
                // Derive from wall clock rather than counting ticks so a suspended
                // process or stalled run loop can't undercount the run (M23).
                self.elapsedSeconds = self.stopwatch.elapsed(at: Date())
            }
        }
    }

    // MARK: - GPS (outdoor)

    private func configureLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5   // metres
        locationManager.activityType = .fitness
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.requestWhenInUseAuthorization()
    }

    private func processLocation(_ location: CLLocation) {
        coordinates.append(Coordinate(location.coordinate))

        if let last = lastLocation {
            let delta = location.distance(from: last)

            // Auto-pause: stop accumulating distance if nearly stationary
            if location.speed >= 0 && location.speed < autoPauseThresholdMetersPerSecond {
                lastLocation = location
                return
            }

            distanceMeters += delta

            // Accumulate positive altitude change across the whole run and the
            // current split so a steady climb is recorded, not just the last
            // fix-to-fix delta (M26).
            let ascent = max(0, location.altitude - last.altitude)
            totalElevationGainMeters += ascent
            currentSplitElevationGainMeters += ascent

            if location.speed > 0 {
                currentPaceSecondsPerKm = 1_000 / location.speed
            }

            // Record a split every unit (km or mile) the runner has chosen
            if SplitBucketing.crossedBoundary(
                previousMeters: lastSplitDistance,
                currentMeters: distanceMeters,
                splitLengthMeters: splitLengthMeters
            ) {
                let unitsCovered = SplitBucketing.bucketIndex(
                    distanceMeters: distanceMeters, splitLengthMeters: splitLengthMeters
                )
                let split = Split(
                    kilometer: unitsCovered,
                    paceSecondsPerKm: currentPaceSecondsPerKm,
                    heartRate: currentHeartRate,
                    elevationGainMeters: currentSplitElevationGainMeters,
                    cumulativeDistanceMeters: distanceMeters
                )
                splits.append(split)
                lastSplitDistance = distanceMeters
                currentSplitElevationGainMeters = 0
            }
        }
        lastLocation = location
    }
}

// MARK: - CLLocationManagerDelegate

extension WorkoutTrackerService: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in processLocation(location) }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        // Non-fatal – location updates will resume on next fix
        AppLogger.log("Location error: \(error.localizedDescription)", label: "WorkoutTrackerService", level: .error)
    }
}
