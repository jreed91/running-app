import ActivityKit
import Foundation

// MARK: - RunActivityPresenting

/// What the tracker needs from the run's Live Activity.
///
/// A protocol so `WorkoutTrackerService` depends on three verbs rather than on ActivityKit:
/// the tracker is the only thing that knows when a run starts, ticks, holds and ends, but
/// it should not be the thing that knows how a Lock Screen works.
@MainActor
protocol RunActivityPresenting: AnyObject {
    func runDidStart(_ snapshot: RunActivitySnapshot)
    func runDidUpdate(_ snapshot: RunActivitySnapshot)
    func runDidEnd(_ snapshot: RunActivitySnapshot)
}

// MARK: - RunActivityController

/// Drives the run's Live Activity — Lock Screen and Dynamic Island — for as long as a run
/// is recording (U5b).
///
/// Why this is driven by the tracker rather than by a view: the case it exists for is a
/// locked phone in a pocket, and SwiftUI does not update a backgrounded view. The tracker's
/// one-second timer keeps running there (the app holds the `location` background mode), so
/// it is the only pulse in the app that survives the situation the activity is *for*.
///
/// Updates are throttled to `RunActivityController.refreshInterval`, with pause and resume
/// pushed the moment they happen. The elapsed clock is not part of that budget at all — the
/// widget counts it itself from the interval in the content state.
@MainActor
final class RunActivityController: RunActivityPresenting {

    /// How often distance and pace are refreshed on the Lock Screen. A second-by-second
    /// push would spend the activity's budget, and its own budget, on numbers that change
    /// by a metre.
    static let refreshInterval: TimeInterval = 5

    private var activity: Activity<RunActivityAttributes>?
    private var lastPush: Date?
    private var lastPushedPauseState: Bool?

    // MARK: RunActivityPresenting

    func runDidStart(_ snapshot: RunActivitySnapshot) {
        guard activity == nil else { return }
        // The runner can turn Live Activities off for Stride in Settings, and asking anyway
        // throws. This is an enhancement to a run, never a precondition for one.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            AppLogger.log(
                "Live Activities are disabled for Stride; the run is recording without one",
                label: "RunActivity"
            )
            return
        }

        let now = Date()
        let attributes = RunActivityAttributes(
            workoutName: snapshot.workoutType.localizedName,
            startedAt: now.addingTimeInterval(-snapshot.elapsedSeconds)
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: RunActivityContent.state(from: snapshot, now: now),
                    staleDate: RunActivityContent.staleDate(from: now)
                ),
                pushType: nil
            )
            lastPush = now
            lastPushedPauseState = snapshot.isPaused
        } catch {
            // A failed request must not take the run with it, so this is logged and dropped.
            AppLogger.log(
                "Couldn't start the run's Live Activity: \(error.localizedDescription)",
                label: "RunActivity",
                level: .error
            )
        }
    }

    func runDidUpdate(_ snapshot: RunActivitySnapshot) {
        guard let activity else { return }
        let now = Date()
        // Pausing and resuming are the two changes a runner is looking at the Lock Screen
        // to confirm, so they jump the queue; everything else waits for the cadence.
        let pauseChanged = lastPushedPauseState != snapshot.isPaused
        let dueForRefresh = lastPush.map { now.timeIntervalSince($0) >= Self.refreshInterval } ?? true
        guard pauseChanged || dueForRefresh else { return }

        lastPush = now
        lastPushedPauseState = snapshot.isPaused
        let content = ActivityContent(
            state: RunActivityContent.state(from: snapshot, now: now),
            staleDate: RunActivityContent.staleDate(from: now)
        )
        Task { await activity.update(content) }
    }

    func runDidEnd(_ snapshot: RunActivitySnapshot) {
        guard let activity else { return }
        self.activity = nil
        lastPush = nil
        lastPushedPauseState = nil
        let content = ActivityContent(
            state: RunActivityContent.state(from: snapshot),
            staleDate: nil
        )
        // Dismissed immediately rather than left to linger: the run's summary is in the
        // app by now, and a Lock Screen card for a run that has stopped recording is a lie
        // about the state of the app.
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }

    // MARK: Recovery

    /// Clears any activity left behind by a previous launch.
    ///
    /// An app killed mid-run — by the system under memory pressure, or by the runner —
    /// leaves its activity on the Lock Screen with no tracker behind it to update or end
    /// it. The run itself cannot be recovered (the tracker's state went with the process),
    /// so the honest thing is to take the card down on the next launch rather than let it
    /// go stale on screen.
    func endActivitiesFromPreviousLaunches() {
        for orphan in Activity<RunActivityAttributes>.activities {
            AppLogger.log(
                "Ending a run Live Activity left over from a previous launch (\(orphan.id))",
                label: "RunActivity"
            )
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
