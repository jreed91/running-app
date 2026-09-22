import Foundation
import Observation

// MARK: - RunRouteGuide

/// Follows a saved route during a run and says so out loud when the runner leaves it (A7).
///
/// Fed by `WorkoutTrackerService.onAcceptedFix` rather than by a view: an off-route
/// warning is only worth anything with the phone in a pocket and the screen off, which is
/// when no view is updating. The tracker is the one pulse that keeps going then — the
/// same reason it, not the HUD, drives the Live Activity.
///
/// Choosing a route to follow is the opt-in, so the warning is spoken whether or not
/// spoken splits are on. The HUD adds a haptic and a banner while it is on screen.
@MainActor
@Observable
final class RunRouteGuide {

    struct FollowedRoute: Equatable {
        let name: String
        let coordinates: [Coordinate]
    }

    /// The route being followed; `nil` when the run follows none.
    private(set) var route: FollowedRoute?
    /// Where the runner is relative to `route`; `nil` until the first fix.
    private(set) var status: RouteDeviationMonitor.Status?

    var isOffRoute: Bool {
        if case .offRoute = status { return true }
        return false
    }

    @ObservationIgnored private var monitor: RouteDeviationMonitor?
    @ObservationIgnored private var unit: UnitPreference = .metric
    @ObservationIgnored private let speak: @MainActor (String) -> Void

    init(speak: @escaping @MainActor (String) -> Void) {
        self.speak = speak
    }

    convenience init(voiceCoach: RunVoiceCoach) {
        self.init { [weak voiceCoach] phrase in voiceCoach?.speak(phrase) }
    }

    /// Starts following `coordinates`. A route with fewer than two points has no line to
    /// follow and is ignored.
    func follow(name: String, coordinates: [Coordinate], unit: UnitPreference) {
        guard coordinates.count >= 2 else { return }
        route = FollowedRoute(name: name, coordinates: coordinates)
        monitor = RouteDeviationMonitor(route: coordinates)
        status = nil
        self.unit = unit
    }

    /// Stops following. Called when the runner clears the choice and when the run ends,
    /// so a finished run's route never carries into the next one.
    func stop() {
        route = nil
        monitor = nil
        status = nil
    }

    /// One fix the tracker accepted into the recorded route.
    func handle(fix: Coordinate) {
        guard var monitor else { return }
        let event = monitor.update(with: fix)
        self.monitor = monitor
        status = monitor.status
        if let event {
            speak(Self.phrase(for: event, unit: unit))
        }
    }

    // MARK: Phrasing

    /// The spoken warning for `event`. Distances are rounded coarsely — "about 60
    /// metres", not "57" — because GPS cannot back the precision and a runner does not
    /// need it to turn around.
    static func phrase(for event: RouteDeviationMonitor.Event, unit: UnitPreference) -> String {
        switch event {
        case .rejoinedRoute:
            return "Back on route."
        case .leftRoute(let meters):
            return "Off route. The route is about \(spokenDistance(meters, unit: unit)) away."
        }
    }

    /// `meters` in the runner's unit: metres to the nearest 10 below a kilometre, feet to
    /// the nearest 50 below a quarter mile, and tenths of a kilometre or mile beyond.
    static func spokenDistance(_ meters: Double, unit: UnitPreference) -> String {
        switch unit {
        case .metric:
            if meters < 1_000 {
                let rounded = max(10, Int((meters / 10).rounded()) * 10)
                return "\(rounded) metres"
            }
            return String(format: "%.1f kilometres", meters / 1_000)
        case .imperial:
            let feet = meters / 0.3048
            if feet < 1_320 {
                let rounded = max(50, Int((feet / 50).rounded()) * 50)
                return "\(rounded) feet"
            }
            return String(format: "%.1f miles", meters / 1_609.344)
        }
    }
}
