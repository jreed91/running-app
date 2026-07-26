import Foundation
import CoreLocation
import CoreMotion
import Observation
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
/// Observation note: the live values below are read straight out of `ActiveRunView.body`,
/// and `@Observable` is what makes that a subscription. Reached through the container as
/// an `ObservableObject` they were not: `@Environment` does not subscribe to one, so
/// nothing invalidated the run HUD when a tick moved the clock — `GuidedWorkoutBanner`
/// took an `@ObservedObject` of its own and refreshed, and the distance, duration, pace,
/// heart-rate, cadence, and elevation cells around it did not (D4).
@Observable
@MainActor
final class WorkoutTrackerService: NSObject {

    // MARK: Live state

    private(set) var trackingState: TrackingState = .idle
    private(set) var workoutLocation: WorkoutLocation = .outdoor
    private(set) var elapsedSeconds: Double = 0
    private(set) var distanceMeters: Double = 0
    private(set) var currentPaceSecondsPerKm: Double = 0
    private(set) var currentHeartRate: Double?
    private(set) var coordinates: [Coordinate] = []
    private(set) var splits: [Split] = []

    /// Elevation gain accumulated across the whole run, in metres.
    ///
    /// Published because the live HUD showed a hardcoded `--` for elevation while
    /// this number was already being accumulated (N20). Also the value stored on the
    /// finished `RunWorkout`.
    private(set) var elevationGainMeters: Double = 0

    /// Reception quality on the outdoor path, or `nil` indoors and before the first
    /// fix of a run.
    ///
    /// `LocationQualityFilter` graded every fix and the verdict never left the
    /// service, so a runner under tree cover saw a plausible pace with no sign that
    /// the fixes behind it were being discarded (U5c). Graded on every delivered
    /// fix — including rejected ones, which are exactly the ones worth knowing about.
    private(set) var gpsSignal: LocationQualityFilter.SignalQuality?

    /// Live cadence in steps per minute, or `nil` before the first pedometer sample.
    ///
    /// `CMPedometer` reports cadence in steps per *second* and needs no permission
    /// beyond the motion access the indoor path already requests, so the HUD's
    /// second hardcoded `--` can show a real number on outdoor runs too (N20).
    private(set) var currentCadenceStepsPerMinute: Double?

    // MARK: Private

    private var workoutType: WorkoutType = .easy
    private var startDate = Date()
    private var timer: Timer?
    private var lastLocation: CLLocation?
    private var lastSplitDistance: Double = 0

    /// Elapsed time and cumulative distance at the moment the current split bucket
    /// opened. A split's pace is Δtime ÷ Δdistance across the bucket (N7), not the
    /// instantaneous or session-average pace that happened to be showing when the
    /// boundary was crossed.
    private var splitStartElapsedSeconds: Double = 0
    private var splitStartDistanceMeters: Double = 0

    /// GPS fixes discarded by `LocationQualityFilter` during this run, by reason.
    /// Logged once at finish so a run recorded through bad reception is diagnosable
    /// from Pulse without a per-fix log line.
    private var rejectedFixCounts: [LocationQualityFilter.Rejection: Int] = [:]

    /// Distance unit splits are bucketed in, captured at `startWorkout` from the user's
    /// preference so an imperial runner gets genuine per-mile splits rather than km
    /// buckets relabelled "mi" (A1). `splitLengthMeters` is the derived bucket size.
    private var splitUnit: UnitPreference = .metric
    private var splitLengthMeters: Double = UnitPreference.metric.splitLengthMeters

    /// Wall-clock elapsed time, immune to process suspension / stalled run loops (M23).
    private var stopwatch = WallClockStopwatch()

    /// Elevation gain accumulated across the current split bucket. (M26 — a split's
    /// gain is the sum of positive altitude deltas within the km, not just the delta
    /// between its final two GPS fixes.) The whole-run total is the published
    /// `elevationGainMeters`.
    private var currentSplitElevationGainMeters: Double = 0

    /// Distance banked from active segments before the current indoor resume, so
    /// resuming the pedometer from "now" no longer replays distance walked while
    /// paused (M24). The pedometer reports cumulative distance since its own start
    /// date, so each active segment is measured independently and summed here.
    private var indoorDistanceBaselineMeters: Double = 0

    private let locationManager = CLLocationManager()
    private let autoPauseThresholdMetersPerSecond: Double = 0.5  // below this ≈ standing still

    /// Weight given to the newest fix in the live pace HUD. A raw `1_000 / speed`
    /// reading swings hard fix-to-fix; splits no longer depend on this value (N7),
    /// so the displayed number can be smoothed.
    private let paceSmoothingFactor: Double = 0.3

    private let hkStore = HKHealthStore()
    private var hrQuery: HKAnchoredObjectQuery?
    private var hrSamples: [Double] = []

    private let pedometer = CMPedometer()
    private var pedometerActive = false

    // MARK: Public API

    /// Whether a run is underway — recording or holding — as opposed to not yet started
    /// or already finished.
    ///
    /// The predicate the minimised-run accessory keys off (U7): a run that outlives the
    /// screen showing it needs one shared answer to "is there a run right now", rather
    /// than each caller spelling out the same two-case comparison.
    var isRecording: Bool {
        trackingState == .active || trackingState == .paused
    }

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
        }
        // The pedometer runs on both paths: indoors it is the distance source,
        // outdoors it is read for cadence only (N20).
        startPedometerUpdates(from: startDate)
    }

    func pauseWorkout() {
        guard trackingState == .active else { return }
        trackingState = .paused
        stopwatch.pause(at: Date())
        elapsedSeconds = stopwatch.accumulated
        timer?.invalidate()
        if workoutLocation == .outdoor {
            locationManager.stopUpdatingLocation()
            // Forget the last fix so the first one after resuming opens a fresh
            // segment: otherwise the distance walked while paused is measured
            // against the pre-pause location and added to the run — the outdoor
            // twin of the pedometer replay M24 fixed.
            lastLocation = nil
        } else {
            // Bank distance covered so far; the next pedometer segment starts fresh
            // from its own resume date so paused walking is not replayed (M24).
            indoorDistanceBaselineMeters = distanceMeters
        }
        stopPedometerUpdates()
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
        }
        startPedometerUpdates(from: Date())
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
        }
        stopPedometerUpdates()
        if let q = hrQuery { hkStore.stop(q); hrQuery = nil }
        stopwatch.pause(at: Date())
        elapsedSeconds = stopwatch.accumulated
        trackingState = .finished
        logRejectedFixSummary()

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
        if elevationGainMeters > 0 {
            workout.elevationGainMeters = elevationGainMeters
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
        splitStartElapsedSeconds = 0
        splitStartDistanceMeters = 0
        elevationGainMeters = 0
        currentSplitElevationGainMeters = 0
        currentCadenceStepsPerMinute = nil
        indoorDistanceBaselineMeters = 0
        pedometerActive = false
        rejectedFixCounts = [:]
        gpsSignal = nil
    }

    /// Opens a new split bucket at the current elapsed time and distance.
    private func openNextSplitBucket(atElapsed elapsed: Double) {
        lastSplitDistance = distanceMeters
        splitStartElapsedSeconds = elapsed
        splitStartDistanceMeters = distanceMeters
    }

    /// Average pace across the split bucket that just closed, falling back to the live
    /// pace only when the bucket has no usable deltas (e.g. a resumed indoor segment
    /// that reports its whole distance in one callback).
    private func closingSplitPace(atElapsed elapsed: Double) -> Double {
        SplitBucketing.splitPaceSecondsPerKm(
            deltaSeconds: elapsed - splitStartElapsedSeconds,
            deltaMeters: distanceMeters - splitStartDistanceMeters
        ) ?? currentPaceSecondsPerKm
    }

    private func logRejectedFixSummary() {
        guard !rejectedFixCounts.isEmpty else { return }
        let summary = rejectedFixCounts
            .sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: ", ")
        AppLogger.log(
            "Discarded low-quality GPS fixes during this run: \(summary)",
            label: "WorkoutTrackerService",
            level: .debug
        )
    }

    // MARK: - Pedometer (distance indoors, cadence on every run)

    /// Starts pedometer updates for the segment beginning at `segmentStart`.
    ///
    /// Indoors the pedometer is the distance source. Outdoors it runs too, but only
    /// cadence is read from it — distance stays with GPS (N20).
    private func startPedometerUpdates(from segmentStart: Date) {
        guard !pedometerActive else { return }
        let providesDistance = workoutLocation == .indoor
        guard CMPedometer.isCadenceAvailable()
            || (providesDistance && CMPedometer.isDistanceAvailable()) else { return }
        pedometerActive = true
        let baseline = indoorDistanceBaselineMeters
        pedometer.startUpdates(from: segmentStart) { [weak self] data, error in
            guard let data, error == nil else { return }
            // `distance` is cumulative since `segmentStart`; add the distance banked
            // before this segment so a pause/resume never replays or drops meters (M24).
            let meters = baseline + (data.distance?.doubleValue ?? 0)
            // Read off `CMPedometerData` here: it is not `Sendable`, so only the
            // extracted numbers cross into the main-actor task.
            let stepsPerMinute = data.currentCadence.map { $0.doubleValue * 60 }
            Task { @MainActor [weak self] in
                guard let self, self.trackingState == .active else { return }
                if let stepsPerMinute, stepsPerMinute > 0 {
                    self.currentCadenceStepsPerMinute = stepsPerMinute
                }
                guard providesDistance else { return }
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
        // `currentPaceSecondsPerKm` on this path is the cumulative session average,
        // so using it made every indoor split report the same number (N7). Take the
        // bucket's own Δtime ÷ Δdistance instead.
        let elapsed = stopwatch.elapsed(at: Date())
        let split = Split(
            kilometer: unitsCovered,
            paceSecondsPerKm: closingSplitPace(atElapsed: elapsed),
            heartRate: currentHeartRate,
            elevationGainMeters: 0,
            cumulativeDistanceMeters: distanceMeters
        )
        splits.append(split)
        openNextSplitBucket(atElapsed: elapsed)
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
        let now = Date()
        let previous = lastLocation

        // Reject unusable fixes before they reach the route or the distance total:
        // an invalid/imprecise reading, a cached one replayed when updates start, or
        // a jump no runner could have made is jitter, not distance (N8).
        let fix = LocationQualityFilter.Fix(
            horizontalAccuracy: location.horizontalAccuracy,
            ageSeconds: now.timeIntervalSince(location.timestamp),
            distanceFromPreviousMeters: previous.map { location.distance(from: $0) },
            secondsSincePreviousFix: previous.map { location.timestamp.timeIntervalSince($0.timestamp) }
        )
        // Graded before the accept/reject decision, so the runner is told reception is
        // poor by the very fixes that are being thrown away rather than by their
        // absence (U5c).
        gpsSignal = LocationQualityFilter.signalQuality(forHorizontalAccuracy: location.horizontalAccuracy)

        if let rejection = LocationQualityFilter.rejection(for: fix) {
            rejectedFixCounts[rejection, default: 0] += 1
            return
        }

        coordinates.append(Coordinate(location.coordinate))

        if let last = previous {
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
            elevationGainMeters += ascent
            currentSplitElevationGainMeters += ascent

            if location.speed > 0 {
                // Live HUD only — smoothed so a single fix can't make the number jump.
                // Splits take their own Δtime ÷ Δdistance below (N7).
                let instantaneous = 1_000 / location.speed
                currentPaceSecondsPerKm = currentPaceSecondsPerKm > 0
                    ? currentPaceSecondsPerKm * (1 - paceSmoothingFactor)
                        + instantaneous * paceSmoothingFactor
                    : instantaneous
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
                let elapsed = stopwatch.elapsed(at: now)
                let split = Split(
                    kilometer: unitsCovered,
                    paceSecondsPerKm: closingSplitPace(atElapsed: elapsed),
                    heartRate: currentHeartRate,
                    elevationGainMeters: currentSplitElevationGainMeters,
                    cumulativeDistanceMeters: distanceMeters
                )
                splits.append(split)
                openNextSplitBucket(atElapsed: elapsed)
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
