import Foundation
import HealthKit

/// What the tracker tells whatever keeps the app running through an indoor run (P2.1).
///
/// A protocol so the tracker can be built without HealthKit in tests and previews, the
/// way it takes its Live Activity through `RunActivityPresenting`.
@MainActor
protocol IndoorRunKeepalive: AnyObject {
    /// An indoor run has started recording.
    func indoorRunDidStart(at date: Date)
    /// The run has finished. Called for every finish, so it must be safe without a start.
    func indoorRunDidEnd()
}

/// Keeps Stride running through an indoor run with the phone locked, using an iPhone
/// workout session (P2.1).
///
/// An outdoor run stays alive through its location session. An indoor run had nothing:
/// the pedometer is its only source, and a locked phone suspended the app, so the Live
/// Activity's distance and pace, the spoken split cues and the 30-second checkpoints all
/// stopped until the runner unlocked. The pedometer replayed the distance on wake, so the
/// run's numbers came out right, but a runner with the phone in a pocket heard no cues and
/// saw a frozen Lock Screen. Since iOS 26 an
/// iPhone app can run an `HKWorkoutSession`, and an app with an active session keeps
/// running while the phone is locked.
///
/// **The session only keeps the app awake.** Its builder never begins collection, so it
/// writes nothing to Health: the run is still saved once, by `HealthKitRepository.save(_:)`,
/// the way every Stride run is. Collecting through the live builder as well would put a
/// second workout, or a second set of distance samples, into Health.
///
/// The session runs until the run finishes, through pauses too: with no builder a pause
/// would change nothing in Health, and a held run still needs its pause checkpoint and
/// its Lock Screen card kept current.
///
/// The first session on a device brings up a system prompt about workout data being
/// available while the phone is locked. That is Apple's, not Stride's.
@MainActor
final class IndoorRunWorkoutSession: NSObject, IndoorRunKeepalive {

    private let healthStore: HKHealthStore
    private var session: HKWorkoutSession?

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        super.init()
    }

    func indoorRunDidStart(at date: Date) {
        guard session == nil, HKHealthStore.isHealthDataAvailable() else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            session.delegate = self
            session.startActivity(with: date)
            self.session = session
            AppLogger.log("Started the indoor run's workout session", label: "ActiveRun", level: .info)
        } catch {
            // The run records exactly as it did before this existed: in the foreground,
            // and caught up from the pedometer whenever the phone is unlocked.
            AppLogger.log(
                "Couldn't start a workout session for an indoor run: \(error.localizedDescription)",
                label: "ActiveRun",
                level: .warning
            )
        }
    }

    func indoorRunDidEnd() {
        guard let session else { return }
        self.session = nil
        // Straight to `end()`: `stopActivity` exists to let a builder collect its final
        // samples, and this session has no builder collecting.
        session.end()
        AppLogger.log("Ended the indoor run's workout session", label: "ActiveRun", level: .info)
    }

    /// Ends a session a previous launch left running. Call at launch, and only while no run
    /// is recording.
    ///
    /// The system keeps a crashed app's workout session and relaunches the app to pick it
    /// up. Stride does not resume a run in progress; it saves the run from its last
    /// checkpoint (`AppContainer.recoverInterruptedRun`). So the session is ended, or it
    /// would hold the app awake, and show a workout in progress, with nothing recording.
    func endLeftoverSession() {
        guard session == nil else { return }
        // `@Sendable`: HealthKit calls this on its own queue, and a closure written in a
        // main-actor type is otherwise inferred main-actor and traps there (PR #358).
        let handler: @Sendable (HKWorkoutSession?, (any Error)?) -> Void = { leftover, _ in
            guard let leftover else { return }
            leftover.end()
            AppLogger.log(
                "Ended a workout session left over from a previous launch",
                label: "ActiveRun",
                level: .info
            )
        }
        healthStore.recoverActiveWorkoutSession(completion: handler)
    }
}

extension IndoorRunWorkoutSession: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        AppLogger.log(
            "Indoor run workout session: \(fromState.rawValue) -> \(toState.rawValue)",
            label: "ActiveRun",
            level: .debug
        )
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        // Another app starting a workout ends this one, among other things. The run keeps
        // recording; it just goes back to being suspended while the phone is locked.
        AppLogger.log(
            "Indoor run workout session failed: \(error.localizedDescription)",
            label: "ActiveRun",
            level: .warning
        )
    }
}
