import Foundation
import Observation
@preconcurrency import WatchConnectivity
@preconcurrency import WorkoutKit

// MARK: - WatchGlanceModel

/// What the watch app shows, and the one thing it does (B3).
///
/// The watch app has no store of its own. Everything it draws is the ``WatchContext`` the
/// iPhone last sent — the same ``WidgetSnapshot`` the Home Screen widgets render — so the
/// wrist and the Home Screen cannot disagree about what today's session is. The system
/// keeps the newest context across launches (`WCSession.receivedApplicationContext`), so
/// the watch has something to show even when the phone is out of reach.
@MainActor
@Observable
final class WatchGlanceModel {

    enum StartState: Equatable {
        case idle
        case opening
        /// The Workout app would not open the plan. Kept as a state rather than an alert:
        /// the card says so in place, beside the button that failed.
        case failed
    }

    /// `nil` until the phone has sent anything, or when what it sent does not decode.
    private(set) var context: WatchContext?
    private(set) var startState: StartState = .idle

    @ObservationIgnored private var receiver: WatchSessionReceiver?

    /// Activates the session and loads whatever context the system already holds.
    func activate() {
        guard receiver == nil, WCSession.isSupported() else { return }
        let receiver = WatchSessionReceiver { [weak self] context in
            Task { @MainActor in self?.apply(context) }
        }
        self.receiver = receiver
        let session = WCSession.default
        session.delegate = receiver
        session.activate()
    }

    private func apply(_ context: WatchContext) {
        self.context = context
        startState = .idle
    }

    /// Opens today's session in the Workout app, as the same structured workout the
    /// phone scheduled there.
    ///
    /// Stride hands the run to Apple's Workout app rather than recording it itself: that
    /// is the path plan workouts already take, and the run comes back into Stride through
    /// HealthKit and is linked to today's plan day like any other Watch run. Recording
    /// in Stride's own app (an `HKWorkoutSession` with live coaching) is the next slice.
    func startToday() async {
        guard let data = context?.startableWorkout, startState != .opening else { return }
        startState = .opening
        do {
            let plan = try WorkoutPlan(from: data)
            try await plan.openInWorkoutApp()
            startState = .idle
        } catch {
            startState = .failed
        }
    }
}

// MARK: - WatchSessionReceiver

/// The `WCSession` delegate, kept apart from the model.
///
/// `WCSessionDelegate` callbacks arrive on a background queue with no isolation, and
/// satisfying the protocol from the main-actor model would mean making its surface
/// `nonisolated`. This decodes on the callback's queue and hands the model a `Sendable`
/// value — the same split `RunVoiceSessionDeactivator` makes in the iPhone app.
private final class WatchSessionReceiver: NSObject, WCSessionDelegate {

    private let deliver: @Sendable (WatchContext) -> Void

    init(deliver: @escaping @Sendable (WatchContext) -> Void) {
        self.deliver = deliver
    }

    /// The last context the phone sent before this launch is already on the watch; this is
    /// the first moment it can be read.
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated,
              let context = WatchContext(applicationContext: session.receivedApplicationContext)
        else { return }
        deliver(context)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let context = WatchContext(applicationContext: applicationContext) else { return }
        deliver(context)
    }
}
