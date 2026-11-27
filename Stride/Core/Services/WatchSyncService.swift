import Foundation
@preconcurrency import WatchConnectivity
@preconcurrency import WorkoutKit

// MARK: - WatchSyncService

/// Sends the Stride watch app what it shows (B3).
///
/// The watch app cannot read the SwiftData store any more than the widgets can, and it is
/// on another device, so the App Group file does not reach it either. This hands it the
/// widgets' own ``WidgetSnapshot`` — plus today's session as a WorkoutKit plan, for the
/// Start button — through WatchConnectivity's application context. See ``WatchContext``.
///
/// A process-wide singleton because `WCSession.default` is one: the session has exactly
/// one delegate, and a second owner would silently take it from the first. It holds no
/// app state beyond the latest context, so it cannot end up pointing at the wrong
/// `AppContainer` the way a stored callback on a singleton can.
///
/// Every failure is silent, like ``WidgetRefreshService``'s. No watch, no paired watch,
/// or the watch app not installed are the common cases, not errors, and a watch one
/// refresh behind is not worth an alert.
@MainActor
final class WatchSyncService: NSObject {

    static let shared = WatchSyncService()

    /// `nil` where WatchConnectivity is unsupported, such as on iPad.
    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil

    /// The newest context, kept after sending so it can be sent again when a watch is
    /// paired or the watch app is installed later — both arrive as a delegate callback with
    /// nothing new to send otherwise.
    private var latest: WatchContext?

    private override init() {
        super.init()
    }

    /// Publishes `snapshot` to the watch, with `nextSession` as the startable workout unless
    /// it is overdue (see ``WatchContext/startableWorkout``).
    ///
    /// Called from ``WidgetRefreshService/refresh(context:appSettings:now:store:reload:)``
    /// so the watch moves whenever the widgets do: launch, plan change, foreground,
    /// background, and right after a run is saved. Unlike the widgets there is no reload
    /// budget to protect — the system keeps only the newest application context — so this
    /// sends whether or not the widgets' snapshot changed.
    func publish(
        snapshot: WidgetSnapshot,
        nextSession: ScheduledWorkout?,
        unit: UnitPreference,
        maxHeartRateBPM: Int? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        latest = WatchContext(
            snapshot: snapshot,
            startableWorkout: Self.startableWorkoutData(
                for: nextSession,
                unit: unit,
                now: now,
                calendar: calendar
            ),
            runSession: Self.runSession(
                for: nextSession,
                unit: unit,
                maxHeartRateBPM: maxHeartRateBPM,
                now: now,
                calendar: calendar
            )
        )
        activateIfNeeded()
        sendLatest()
    }

    /// Blanks the watch — for "reset all data", where the watch would otherwise be the one
    /// place the deleted plan survived.
    func clear() {
        latest = WatchContext(snapshot: .empty())
        sendLatest()
    }

    /// The next non-rest session, today's or later, as `WorkoutPlan.dataRepresentation`,
    /// or `nil`.
    ///
    /// Sent ahead of its day. Gating on "today" here meant the phone had to publish on the
    /// session's own day, and a morning runner whose phone app last ran the evening before
    /// found no Start on the Watch (P2.2). The watch already holds the button back until
    /// the day comes (``WatchContext/canStart(asOf:calendar:)``), so an overdue session is
    /// the only thing left to refuse here.
    ///
    /// Built by the same `HealthKitRepository.makeWorkoutPlan` that schedules the plan in
    /// the Workout app, and carrying the session's own id — the id the scheduled copy
    /// already has.
    static func startableWorkoutData(
        for session: ScheduledWorkout?,
        unit: UnitPreference,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Data? {
        guard let session = sendable(session, now: now, calendar: calendar) else { return nil }
        return try? HealthKitRepository
            .makeWorkoutPlan(for: session, unitPreference: unit)
            .dataRepresentation
    }

    /// The next session in Stride's own terms, for the watch app to record itself, under
    /// the same rules as ``startableWorkoutData(for:unit:now:calendar:)``.
    static func runSession(
        for session: ScheduledWorkout?,
        unit: UnitPreference,
        maxHeartRateBPM: Int?,
        spokenCues: (splits: Bool, steps: Bool) = AppSettings.syncedSpokenCues(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WatchRunSession? {
        guard let session = sendable(session, now: now, calendar: calendar) else { return nil }
        return WatchRunSession(
            sessionID: session.id,
            scheduledDate: session.scheduledDate,
            title: session.displayTitle,
            targetDistanceMeters: session.targetDistanceMeters,
            targetPaceLowerSecondsPerKm: session.targetPaceRange?.lowerBound,
            targetPaceUpperSecondsPerKm: session.targetPaceRange?.upperBound,
            structure: session.workoutStructure,
            usesRunWalkCues: ActiveRunPresentation.cueStyle(for: session) == .runWalk,
            maxHeartRateBPM: maxHeartRateBPM.flatMap { $0 > 0 ? $0 : nil },
            usesMetricUnits: unit == .metric,
            speaksSplits: spokenCues.splits,
            speaksSteps: spokenCues.steps
        )
    }

    /// `session` when the watch may be sent it: not a rest day, not done, not overdue.
    private static func sendable(
        _ session: ScheduledWorkout?,
        now: Date,
        calendar: Calendar
    ) -> ScheduledWorkout? {
        guard let session,
              session.workoutType != .rest,
              !session.isCompleted,
              session.scheduledDate >= calendar.startOfDay(for: now)
        else { return nil }
        return session
    }

    // MARK: - Session

    private func activateIfNeeded() {
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    private func sendLatest() {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled,
              let latest
        else { return }
        do {
            try session.updateApplicationContext(latest.applicationContext())
        } catch {
            AppLogger.log(
                "Watch context not sent: \(error.localizedDescription)",
                label: "Watch",
                level: .debug
            )
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSyncService: WCSessionDelegate {

    /// Activation is asynchronous, so the first ``publish`` of a launch usually lands before
    /// it completes. This is where that context actually goes out.
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor in self.sendLatest() }
    }

    /// Pairing a watch, or installing the watch app, after the context was published.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.sendLatest() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The runner switched to another watch. Apple's documented response is to activate
    /// again, which is what lets the new watch receive a context at all.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
