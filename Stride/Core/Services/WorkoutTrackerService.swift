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
// No longer an `NSObject`: the only reason it ever was is that
// `CLLocationManagerDelegate` requires one, and fixes now arrive over an
// `AsyncSequence` instead.
final class WorkoutTrackerService {

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

    /// Boundaries of the laps the runner has marked by hand, oldest first (A2).
    ///
    /// Published rather than private because the HUD counts them: the runner is on lap
    /// `lapMarks.count + 1`. `LapRecorder` turns them into ``Lap`` values here and on the
    /// run summary, so both read the boundaries the same way.
    private(set) var lapMarks: [LapRecorder.Mark] = []

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

    /// Cumulative distance readings for the run, persisted at finish so the run summary's
    /// split charts can re-bucket a short run at a finer resolution than the whole mile its
    /// splits close on (N34). Sampled rather than taken per fix — see
    /// `distanceSeriesResolutionMeters`.
    private var distanceSeries: [SplitBucketing.DistancePoint] = []

    /// How far the runner must cover before another distance reading is banked.
    ///
    /// Ten metres is a quarter of the finest bucket the charts will draw (a tenth of a
    /// kilometre), so the interpolation that finds a boundary crossing has something close
    /// on either side of it, and an hour's run stores a few hundred readings rather than a
    /// few thousand.
    private let distanceSeriesResolutionMeters: Double = 10

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

    /// Kept only to ask for authorization. Fixes themselves arrive through
    /// `CLLocationUpdate.liveUpdates(.fitness)` — see `startLocationUpdates()`.
    private let locationManager = CLLocationManager()

    /// The `for await` loop consuming `CLLocationUpdate.liveUpdates`, and the session
    /// that entitles it to keep running with the app in the background.
    private var locationTask: Task<Void, Never>?
    private var backgroundActivitySession: CLBackgroundActivitySession?

    private let autoPauseThresholdMetersPerSecond: Double = 0.5  // below this ≈ standing still

    /// Minimum movement between two *accepted* fixes, in metres.
    ///
    /// This used to be `CLLocationManager.distanceFilter`, which the live-updates API
    /// does not expose — `.fitness` picks the accuracy but delivers every fix it gets.
    /// Without a replacement, a phone sitting still on a start line accumulates real
    /// distance out of GPS jitter, a metre or two at a time, which is precisely the
    /// number this whole service exists to get right. `LocationQualityFilter` does not
    /// cover it: it rejects fixes that are inaccurate, stale, or impossibly far, and
    /// jitter is none of those.
    private let minimumFixSeparationMeters: Double = 5

    /// Weight given to the newest fix in the live pace HUD. A raw `1_000 / speed`
    /// reading swings hard fix-to-fix; splits no longer depend on this value (N7),
    /// so the displayed number can be smoothed.
    private let paceSmoothingFactor: Double = 0.3

    private let hkStore = HKHealthStore()
    private var hrQuery: HKAnchoredObjectQuery?
    private var hrSamples: [Double] = []

    private let pedometer = CMPedometer()
    private var pedometerActive = false

    /// Every cadence reading the pedometer delivered during the run, averaged onto the
    /// finished `RunWorkout` (A5). The live HUD only ever needed the newest one, so this
    /// number used to end with the run.
    private var cadenceSamples: [Double] = []

    /// The run's Live Activity (U5b), if one is wired up.
    ///
    /// Held weakly because `AppContainer` owns it, and driven from here rather than from a
    /// view because the case a Live Activity exists for is a locked phone: SwiftUI does not
    /// update a backgrounded view, while this service's one-second timer keeps running
    /// there. Optional so tests and previews construct a tracker without one.
    @ObservationIgnored weak var activityPresenter: RunActivityPresenting?

    /// Called with every fix accepted into `coordinates` — what `RunRouteGuide` checks
    /// against the route being followed (A7). A hook rather than something a view
    /// observes, for the reason `activityPresenter` is: the off-route warning matters most
    /// on a locked phone, where no view updates.
    @ObservationIgnored var onAcceptedFix: (@MainActor (Coordinate) -> Void)?

    /// What `onPulse` reports.
    enum Pulse: Equatable, Sendable {
        /// A run has just started recording.
        case started
        /// The per-second timer, while recording. Distance and splits are current.
        case tick
    }

    /// Called when a run starts and on every timer tick while it records — what
    /// `RunSpokenCues` speaks splits and guided steps from. A hook for the same reason as
    /// `onAcceptedFix`: those cues matter most on a locked phone, where no view updates.
    @ObservationIgnored var onPulse: (@MainActor (Pulse) -> Void)?

    /// This run as the Live Activity needs it. Assembled here because the tracker is the
    /// only holder of all of it, and handed over as a value so ActivityKit stays out of
    /// this file.
    private var activitySnapshot: RunActivitySnapshot {
        RunActivitySnapshot(
            elapsedSeconds: elapsedSeconds,
            distanceMeters: distanceMeters,
            paceSecondsPerKm: currentPaceSecondsPerKm,
            isPaused: trackingState == .paused,
            unit: splitUnit,
            workoutType: workoutType
        )
    }

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

    // MARK: Laps (A2)

    /// The lap the runner is currently in, 1-based. A run that has never been lapped is on
    /// lap 1, which is why the HUD only shows this once a lap has actually been marked.
    var currentLapNumber: Int { lapMarks.count + 1 }

    /// Distance covered since the current lap opened, in metres.
    var currentLapDistanceMeters: Double {
        max(0, distanceMeters - (lapMarks.last?.distanceMeters ?? 0))
    }

    /// Elapsed time in the current lap, in seconds.
    var currentLapElapsedSeconds: Double {
        max(0, elapsedSeconds - (lapMarks.last?.elapsedSeconds ?? 0))
    }

    /// Average pace across the current lap so far, in seconds per kilometre, or `nil`
    /// before the lap has covered measurable ground.
    var currentLapPaceSecondsPerKm: Double? {
        SplitBucketing.splitPaceSecondsPerKm(
            deltaSeconds: currentLapElapsedSeconds,
            deltaMeters: currentLapDistanceMeters
        )
    }

    /// Closes the current lap and opens the next one.
    ///
    /// Only while recording: a lap marked before the start or after the finish has no run
    /// to belong to. Paused counts as recording — a runner who stops at the top of a climb
    /// and then marks it means the boundary, not the hold.
    func markLap() {
        guard isRecording else { return }
        lapMarks.append(
            LapRecorder.Mark(elapsedSeconds: elapsedSeconds, distanceMeters: distanceMeters)
        )
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
            startLocationUpdates()
        }
        // The pedometer runs on both paths: indoors it is the distance source,
        // outdoors it is read for cadence only (N20).
        startPedometerUpdates(from: startDate)
        activityPresenter?.runDidStart(activitySnapshot)
        onPulse?(.started)
    }

    func pauseWorkout() {
        guard trackingState == .active else { return }
        trackingState = .paused
        stopwatch.pause(at: Date())
        elapsedSeconds = stopwatch.accumulated
        timer?.invalidate()
        if workoutLocation == .outdoor {
            stopLocationUpdates()
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
        // Pushed straight through rather than waiting for the refresh cadence: a hold is
        // one of the two things a runner checks the Lock Screen to confirm.
        activityPresenter?.runDidUpdate(activitySnapshot)
    }

    func resumeWorkout() {
        guard trackingState == .paused else { return }
        trackingState = .active
        stopwatch.resume(at: Date())
        startTimer()
        startHeartRateQuery(from: Date())
        if workoutLocation == .outdoor {
            startLocationUpdates()
        }
        startPedometerUpdates(from: Date())
        activityPresenter?.runDidUpdate(activitySnapshot)
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
            stopLocationUpdates()
        }
        stopPedometerUpdates()
        if let q = hrQuery { hkStore.stop(q); hrQuery = nil }
        stopwatch.pause(at: Date())
        elapsedSeconds = stopwatch.accumulated
        trackingState = .finished
        logRejectedFixSummary()
        // Before the `RunWorkout` is built, so the card comes down as the run stops rather
        // than after the save round-trip — which can fail and stay on screen (N15).
        activityPresenter?.runDidEnd(activitySnapshot)

        let workout = RunWorkout(
            date: startDate,
            distanceMeters: distanceMeters,
            durationSeconds: elapsedSeconds,
            workoutType: workoutType,
            workoutLocation: workoutLocation
        )
        // The reading the run stopped on, so the final bucket the charts draw is bounded by
        // where the runner actually finished rather than by the last banked point (N34).
        recordDistancePoint(atElapsed: elapsedSeconds, altitude: lastLocation?.altitude, force: true)

        workout.routeCoordinates = coordinates
        workout.splits = splits
        workout.splitUnit = splitUnit
        workout.distanceSeries = distanceSeries
        // The final lap is closed by the finish itself, so the run keeps every boundary the
        // runner marked rather than losing the one they were in when they stopped (A2).
        workout.laps = LapRecorder.laps(
            marks: lapMarks,
            finish: LapRecorder.Mark(elapsedSeconds: elapsedSeconds, distanceMeters: distanceMeters)
        )
        if elevationGainMeters > 0 {
            workout.elevationGainMeters = elevationGainMeters
        }
        if !cadenceSamples.isEmpty {
            workout.averageCadenceStepsPerMinute =
                cadenceSamples.reduce(0, +) / Double(cadenceSamples.count)
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
        distanceSeries = []
        elevationGainMeters = 0
        currentSplitElevationGainMeters = 0
        currentCadenceStepsPerMinute = nil
        cadenceSamples = []
        lapMarks = []
        indoorDistanceBaselineMeters = 0
        pedometerActive = false
        rejectedFixCounts = [:]
        gpsSignal = nil
    }

    /// Banks a cumulative distance reading, if the runner has covered enough ground since
    /// the last one to be worth another point (N34).
    ///
    /// `force` bypasses the spacing rule for the reading taken at finish, so the last
    /// partial bucket has an end point to interpolate against.
    private func recordDistancePoint(atElapsed elapsed: Double, altitude: Double?, force: Bool = false) {
        let advanced = distanceMeters - (distanceSeries.last?.cumulativeMeters ?? 0)
        guard force || advanced >= distanceSeriesResolutionMeters else { return }
        guard elapsed.isFinite, distanceMeters.isFinite else { return }
        distanceSeries.append(
            SplitBucketing.DistancePoint(
                elapsedSeconds: elapsed,
                cumulativeMeters: distanceMeters,
                altitudeMeters: altitude
            )
        )
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
        // `@Sendable` is load-bearing. CoreMotion calls this on its own queue, and a bare
        // closure written inside this main-actor class is inferred main-actor isolated,
        // so Swift 6 asserts the executor on entry and traps (EXC_BREAKPOINT in
        // libdispatch) on the first pedometer update of every run. The heart-rate
        // handler below is typed `@Sendable` for the same reason.
        let handler: @Sendable (CMPedometerData?, (any Error)?) -> Void = { [weak self] data, error in
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
                    // Kept, not just displayed: the run's mean cadence is what the coach
                    // reads for form, and it can only be built while the run happens (A5).
                    self.cadenceSamples.append(stepsPerMinute)
                }
                guard providesDistance else { return }
                self.distanceMeters = meters
                // Guard the divisor, not the elapsed time (M25) — otherwise the first
                // callbacks (meters == 0) produce a +inf pace.
                if meters > 0 {
                    self.currentPaceSecondsPerKm = self.elapsedSeconds / meters * 1_000
                }
                // No altitude on the pedometer path, so an indoor run's re-bucketed splits
                // report no gain — which is what a treadmill has.
                self.recordDistancePoint(atElapsed: self.stopwatch.elapsed(at: Date()), altitude: nil)
                self.updateSplitsForIndoor()
            }
        }
        pedometer.startUpdates(from: segmentStart, withHandler: handler)
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
                // The Live Activity's pulse. It throttles internally — this fires every
                // second, the Lock Screen refreshes every five, and the elapsed clock is
                // counted by the widget rather than pushed at all (U5b).
                self.activityPresenter?.runDidUpdate(self.activitySnapshot)
                self.onPulse?(.tick)
            }
        }
    }

    // MARK: - GPS (outdoor)

    /// Starts (or restarts) the flow of GPS fixes for the outdoor path.
    ///
    /// Replaces the `CLLocationManagerDelegate` pairing this service used to carry.
    /// `CLLocationUpdate.liveUpdates(.fitness)` is the modern form: `.fitness` selects
    /// the accuracy and activity type that `desiredAccuracy` /`activityType` used to be
    /// set by hand, and delivery is an `AsyncSequence`, so the fix-handling code reads
    /// top-to-bottom on the main actor instead of hopping there from a nonisolated
    /// callback.
    ///
    /// `CLBackgroundActivitySession` replaces `allowsBackgroundLocationUpdates = true`.
    /// It is the difference between a flag that silently entitles the app to track
    /// forever and a session with a lifetime: it shows the runner the system's
    /// background-location indicator while it is alive, and `stopLocationUpdates()`
    /// ends it on pause, finish, and discard alike.
    private func startLocationUpdates() {
        guard locationTask == nil else { return }

        locationManager.requestWhenInUseAuthorization()
        backgroundActivitySession = CLBackgroundActivitySession()

        locationTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                    guard let self, !Task.isCancelled else { return }
                    // An update can carry no fix — Core Location signals state changes
                    // (it has decided the device has settled, authorization moved)
                    // through the same stream. Nothing to process on those.
                    guard let location = update.location else { continue }
                    self.processLocation(location)
                }
            } catch {
                AppLogger.log(
                    "Location updates ended: \(error.localizedDescription)",
                    label: "WorkoutTrackerService",
                    level: .error
                )
            }
        }
    }

    private func stopLocationUpdates() {
        locationTask?.cancel()
        locationTask = nil
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil
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

        // The software replacement for `distanceFilter` (see
        // `minimumFixSeparationMeters`). Deliberately *after* the quality grading above,
        // so a runner standing still under bad reception still sees their signal
        // strength update, and *before* anything that accumulates: a fix this close to
        // the last one contributes nothing but noise to distance, elevation and pace.
        if let last = previous, location.distance(from: last) < minimumFixSeparationMeters {
            return
        }

        let accepted = Coordinate(location.coordinate)
        coordinates.append(accepted)
        onAcceptedFix?(accepted)

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

            recordDistancePoint(
                atElapsed: stopwatch.elapsed(at: now), altitude: location.altitude
            )

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

// The `CLLocationManagerDelegate` conformance that used to live here is gone: fixes
// arrive through `CLLocationUpdate.liveUpdates` in `startLocationUpdates()`, and the
// error path is the `catch` on that loop. `locationManager` survives only to ask for
// authorization.
