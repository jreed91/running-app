import Foundation
import HealthKit
import Combine

/// Manages an `HKWorkoutSession` on the watch and publishes live metrics.
@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {

    // MARK: Published

    @Published private(set) var isRunning = false
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var distanceMeters: Double = 0
    @Published private(set) var currentPaceSecondsPerKm: Double = 0

    // MARK: Unit preference (read from shared UserDefaults)

    private var unitPreference: WatchUnitPreference {
        let raw = UserDefaults.standard.string(forKey: "unitPreference") ?? ""
        return WatchUnitPreference(rawValue: raw) ?? .metric
    }

    // MARK: Formatted helpers

    var elapsedTimeString: String { elapsedSeconds.durationString }
    var distanceString: String { distanceMeters.distanceString(unit: unitPreference) }
    var distanceUnitLabel: String { unitPreference == .imperial ? "MI" : "KM" }
    var currentPaceString: String { currentPaceSecondsPerKm.paceString(unit: unitPreference) }

    // MARK: Private

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var timer: Timer?

    // MARK: Public API

    func startWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor

        do {
            let newSession = try HKWorkoutSession(healthStore: store, configuration: config)
            let newBuilder = newSession.associatedWorkoutBuilder()
            newBuilder.dataSource = HKLiveWorkoutDataSource(
                healthStore: store,
                workoutConfiguration: config
            )
            newSession.delegate = self
            newBuilder.delegate = self
            session = newSession
            builder = newBuilder

            newSession.startActivity(with: Date())
            newBuilder.beginCollection(withStart: Date()) { _, _ in }
            isRunning = true
            startTimer()
        } catch {
            print("[WatchWorkoutManager] Failed to start session: \(error)")
        }
    }

    func togglePause() {
        guard let session else { return }
        if isRunning {
            session.pause()
            timer?.invalidate()
            isRunning = false
        } else {
            session.resume()
            startTimer()
            isRunning = true
        }
    }

    func endWorkout() {
        session?.end()
        timer?.invalidate()
        isRunning = false
    }

    // MARK: Private

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            Task { @MainActor in self.elapsedSeconds += 1 }
        }
    }

    private func updateMetrics(from statistics: HKStatistics) {
        switch statistics.quantityType {
        case HKQuantityType(.distanceWalkingRunning):
            let meters = statistics.sumQuantity()?.doubleValue(for: .meter()) ?? 0
            distanceMeters = meters
            if elapsedSeconds > 0 {
                currentPaceSecondsPerKm = elapsedSeconds / (meters / 1_000)
            }
        default:
            break
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        print("[WatchWorkoutManager] Session error: \(error)")
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType,
                  let statistics = workoutBuilder.statistics(for: quantityType) else { continue }
            Task { @MainActor in updateMetrics(from: statistics) }
        }
    }
}

// MARK: - Formatting helpers (duplicated from iOS target – watch has no shared module yet)

private enum WatchUnitPreference: String {
    case metric = "metric"
    case imperial = "imperial"
}

private extension Double {
    var durationString: String {
        guard self > 0 && isFinite else { return "0:00" }
        let total = Int(self)
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    func distanceString(unit: WatchUnitPreference) -> String {
        switch unit {
        case .metric: return String(format: "%.2f", self / 1_000)
        case .imperial: return String(format: "%.2f", self / 1_609.344)
        }
    }

    func paceString(unit: WatchUnitPreference) -> String {
        guard self > 0 && isFinite else { return "--:--" }
        let secs: Double
        switch unit {
        case .metric: secs = self
        case .imperial: secs = self * 1.60934
        }
        let total = Int(secs)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
