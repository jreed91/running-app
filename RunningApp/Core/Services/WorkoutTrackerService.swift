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

    private let locationManager = CLLocationManager()
    private let autoPauseThresholdMs: Double = 500  // < 0.5 m/s ≈ standing still

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

    func startWorkout(type: WorkoutType) {
        guard trackingState == .idle else { return }
        workoutType = type
        startDate = Date()
        reset()
        trackingState = .active
        startTimer()
        startHeartRateQuery(from: startDate)

        if workoutLocation == .outdoor {
            configureLocationManager()
            locationManager.startUpdatingLocation()
        } else {
            startPedometerUpdates()
        }
    }

    func pauseWorkout() {
        guard trackingState == .active else { return }
        trackingState = .paused
        timer?.invalidate()
        if workoutLocation == .outdoor {
            locationManager.stopUpdatingLocation()
        } else {
            stopPedometerUpdates()
        }
        if let q = hrQuery { hkStore.stop(q) }
    }

    func resumeWorkout() {
        guard trackingState == .paused else { return }
        trackingState = .active
        startTimer()
        startHeartRateQuery(from: Date())
        if workoutLocation == .outdoor {
            locationManager.startUpdatingLocation()
        } else {
            startPedometerUpdates()
        }
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
        if !hrSamples.isEmpty {
            workout.averageHeartRate = hrSamples.reduce(0, +) / Double(hrSamples.count)
        }
        return workout
    }

    // MARK: Private helpers

    private func reset() {
        elapsedSeconds = 0
        distanceMeters = 0
        currentPaceSecondsPerKm = 0
        currentHeartRate = nil
        coordinates = []
        splits = []
        hrSamples = []
        lastLocation = nil
        lastSplitDistance = 0
        pedometerActive = false
    }

    // MARK: - Pedometer (indoor)

    private func startPedometerUpdates() {
        guard CMPedometer.isDistanceAvailable(), !pedometerActive else { return }
        pedometerActive = true
        pedometer.startUpdates(from: startDate) { [weak self] data, error in
            guard let data, error == nil else { return }
            let meters = data.distance?.doubleValue ?? 0
            Task { @MainActor [weak self] in
                guard let self, self.trackingState == .active else { return }
                self.distanceMeters = meters
                if self.elapsedSeconds > 0 {
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
        let kmCovered = Int(distanceMeters / 1_000)
        let lastKmCovered = Int(lastSplitDistance / 1_000)
        guard kmCovered > lastKmCovered else { return }
        let split = Split(
            kilometer: kmCovered,
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
            guard let self, self.trackingState == .active else { return }
            Task { @MainActor in self.elapsedSeconds += 1 }
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
            if location.speed >= 0 && location.speed < autoPauseThresholdMs {
                lastLocation = location
                return
            }

            distanceMeters += delta

            if location.speed > 0 {
                currentPaceSecondsPerKm = 1_000 / location.speed
            }

            // Record a split every kilometre
            let kmCovered = Int(distanceMeters / 1_000)
            let lastKmCovered = Int(lastSplitDistance / 1_000)
            if kmCovered > lastKmCovered {
                let split = Split(
                    kilometer: kmCovered,
                    paceSecondsPerKm: currentPaceSecondsPerKm,
                    heartRate: currentHeartRate,
                    elevationGainMeters: max(0, location.altitude - (last.altitude)),
                    cumulativeDistanceMeters: distanceMeters
                )
                splits.append(split)
                lastSplitDistance = distanceMeters
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
        print("[WorkoutTrackerService] Location error: \(error.localizedDescription)")
    }
}
