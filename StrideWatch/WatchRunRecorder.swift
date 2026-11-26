import CoreLocation
import Foundation
// `@preconcurrency`: the builders are used from the main actor and awaited into
// HealthKit's own async methods, and not every HealthKit class is annotated `Sendable`.
@preconcurrency import HealthKit
import Observation
import WatchKit

// MARK: - WatchRunRecorder

/// Records an outdoor run on the Watch itself, without the iPhone (Watch runs, PR 2).
///
/// An `HKWorkoutSession` keeps the app running with the screen down and turns on the
/// Watch's heart-rate and motion sensors; its `HKLiveWorkoutBuilder` collects distance,
/// heart rate and speed; an `HKWorkoutRouteBuilder` keeps the GPS route. Finishing saves
/// one `HKWorkout` to Apple Health, and the phone imports it the way it already imports
/// runs from Apple's Workout app.
///
/// Every framework callback below is a `nonisolated` delegate method that hands values to
/// the main actor through a `Task`. Callbacks written as closures inside this
/// `@MainActor` type would inherit its isolation and trap on device when HealthKit calls
/// them from its own queue (PR #358).
@MainActor
@Observable
final class WatchRunRecorder: NSObject {

    enum State: Equatable {
        case idle
        case starting
        case running
        case paused
        case saving
        /// The run is in Apple Health. `metrics` is the final reading, for the summary.
        case finished(WatchRunMetrics)
        /// Nothing was recorded, or nothing could be saved. Shown in place, not as an alert.
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var metrics: WatchRunMetrics = .zero
    /// The plan session being run, or `nil` for a free run.
    private(set) var runSession: WatchRunSession?
    /// Display units for this run: the plan's when there is one, else kilometres.
    private(set) var usesMetricUnits = true
    /// The plan session's steps, when it has any (PR 3). `nil` on a free run or an easy run.
    private(set) var guided: WatchGuidedRun?

    @ObservationIgnored private var cues = WatchRunCues(unit: .metric, speaksSplits: false, speaksSteps: false)
    @ObservationIgnored private let voice = WatchRunVoice()
    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var routeBuilder: HKWorkoutRouteBuilder?
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var lastAcceptedLocation: CLLocation?

    var isActive: Bool {
        switch state {
        case .starting, .running, .paused, .saving: return true
        case .idle, .finished, .failed: return false
        }
    }

    // MARK: Permissions

    private static let shareTypes: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
    private static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.heartRate),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.runningSpeed),
        HKQuantityType(.activeEnergyBurned),
    ]

    // MARK: Start

    /// Starts recording. `runSession` is the plan session it fulfils, or `nil` for a free run.
    func start(runSession: WatchRunSession?, fallbackMetric: Bool = true) async {
        guard !isActive else { return }
        self.runSession = runSession
        usesMetricUnits = runSession?.usesMetricUnits ?? fallbackMetric
        guided = runSession.flatMap(WatchGuidedRun.init(session:))
        cues = WatchRunCues(session: runSession, fallbackUnit: usesMetricUnits ? .metric : .imperial)
        metrics = .zero
        state = .starting

        guard HKHealthStore.isHealthDataAvailable() else {
            state = .failed(String(localized: "Apple Health isn't available on this Watch."))
            return
        }
        do {
            try await healthStore.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
        } catch {
            state = .failed(String(localized: "Stride needs Apple Health access to record runs."))
            return
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)

            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            if let id = runSession?.sessionID {
                try? await builder.addMetadata([WatchRunMetadata.sessionIDKey: id.uuidString])
            }
            startLocationUpdates()
            state = .running
            if let first = cues.startPhrase(guided: guided) { voice.speak([first]) }
        } catch {
            reset()
            state = .failed(String(localized: "The run couldn't start. Try again."))
        }
    }

    // MARK: Pause, resume, end

    func pause() {
        guard state == .running else { return }
        session?.pause()
    }

    func resume() {
        guard state == .paused else { return }
        session?.resume()
    }

    /// Ends the run and saves it to Apple Health.
    func end() async {
        guard let session, let builder, state == .running || state == .paused else { return }
        state = .saving
        voice.stop()
        locationManager.stopUpdatingLocation()
        let end = Date()
        session.end()
        let final = currentMetrics(at: end)
        do {
            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else {
                throw CocoaError(.fileWriteUnknown)
            }
            if let routeBuilder {
                _ = try? await routeBuilder.finishRoute(with: workout, metadata: nil)
            }
            reset()
            state = .finished(final)
        } catch {
            reset()
            state = .failed(String(localized: "The run couldn't be saved to Apple Health."))
        }
    }

    /// Back to the home screen after the summary or an error.
    func dismiss() {
        guard !isActive else { return }
        state = .idle
        runSession = nil
        guided = nil
        metrics = .zero
    }

    // MARK: Steps

    /// The runner's "Next step": ends an open step, or cuts one short.
    func skipStep() {
        guard state == .running, var guided else { return }
        refresh()
        let before = guided
        if guided.skip(with: metrics) {
            self.guided = guided
            Self.playStepHaptic()
            speakCues(guidedBefore: before)
        }
    }

    /// Moves the steps on as the run's numbers arrive. Only while running: elapsed time
    /// does not move while paused, so a time step cannot finish during a pause anyway.
    private func advanceSteps() {
        guard state == .running else { return }
        let before = guided
        if var guided, guided.update(with: metrics) > 0 {
            self.guided = guided
            Self.playStepHaptic()
        }
        speakCues(guidedBefore: before)
    }

    /// Speaks what this reading calls for (PR 4). Splits and steps each follow their own
    /// switch in the phone's Settings, sent over with the session; a free run speaks
    /// nothing until a later PR sends the switches without a session.
    private func speakCues(guidedBefore: WatchGuidedRun?) {
        guard !cues.isSilent else { return }
        let phrases = cues.phrases(for: metrics, guidedBefore: guidedBefore, guidedAfter: guided)
        voice.speak(phrases)
    }

    private static func playStepHaptic() {
        WKInterfaceDevice.current().play(.notification)
    }

    // MARK: Live metrics

    /// Re-reads the builder. The run screen calls this once a second from its timeline, so
    /// the clock moves even between HealthKit's own updates.
    func refresh(at date: Date = Date()) {
        guard builder != nil, isActive else { return }
        metrics = currentMetrics(at: date)
        advanceSteps()
    }

    private func currentMetrics(at date: Date) -> WatchRunMetrics {
        guard let builder else { return metrics }
        let distance = builder.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter()) ?? 0
        let speed = builder.statistics(for: HKQuantityType(.runningSpeed))?
            .mostRecentQuantity()?.doubleValue(for: .meter().unitDivided(by: .second()))
        let heartRate = builder.statistics(for: HKQuantityType(.heartRate))?
            .mostRecentQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
        return WatchRunMetrics(
            elapsedSeconds: builder.elapsedTime(at: date),
            distanceMeters: distance,
            currentSpeedMetersPerSecond: speed,
            heartRateBPM: heartRate
        )
    }

    // MARK: Location

    private func startLocationUpdates() {
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // No `allowsBackgroundLocationUpdates`: setting it without the `location`
        // background mode is a CoreLocation assertion, which crashed the app the moment a
        // run started. The running `HKWorkoutSession` already keeps the app, and its
        // location updates, going with the wrist down.
        locationManager.requestWhenInUseAuthorization()
        lastAcceptedLocation = nil
        locationManager.startUpdatingLocation()
    }

    /// Keeps the fixes `LocationQualityFilter` accepts (the phone's own rules) and adds
    /// them to the route.
    private func record(_ locations: [CLLocation]) {
        guard state == .running, let routeBuilder else { return }
        var accepted: [CLLocation] = []
        for location in locations {
            let previous = lastAcceptedLocation
            let fix = LocationQualityFilter.Fix(
                horizontalAccuracy: location.horizontalAccuracy,
                ageSeconds: -location.timestamp.timeIntervalSinceNow,
                distanceFromPreviousMeters: previous.map { location.distance(from: $0) },
                secondsSincePreviousFix: previous.map { location.timestamp.timeIntervalSince($0.timestamp) }
            )
            guard LocationQualityFilter.accepts(fix) else { continue }
            accepted.append(location)
            lastAcceptedLocation = location
        }
        guard !accepted.isEmpty else { return }
        // The async form, not the completion handler: a closure written here would be
        // main-actor isolated and trap when HealthKit calls it on its own queue (#358).
        Task { try? await routeBuilder.insertRouteData(accepted) }
    }

    // MARK: Session state

    private func apply(_ newState: HKWorkoutSessionState) {
        switch newState {
        case .running:
            if state == .paused {
                lastAcceptedLocation = nil // no straight line across the pause
                state = .running
            }
        case .paused:
            if state == .running { state = .paused }
        default:
            break
        }
    }

    private func fail(_ message: String) {
        voice.stop()
        locationManager.stopUpdatingLocation()
        session?.end()
        reset()
        state = .failed(message)
    }

    private func reset() {
        session = nil
        builder = nil
        routeBuilder = nil
        lastAcceptedLocation = nil
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchRunRecorder: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in self.apply(toState) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        Task { @MainActor in
            guard self.isActive, self.state != .saving else { return }
            self.fail(String(localized: "The run stopped unexpectedly."))
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WatchRunRecorder: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - CLLocationManagerDelegate

extension WatchRunRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.record(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
