import Foundation

// MARK: - WatchContext

/// Everything the iPhone app hands the Stride watch app (B3), in one value.
///
/// Compiled into both the app and `StrideWatch`, for the reason ``WidgetSnapshot`` is
/// shared: the phone writes it and the watch reads it, and one definition is what keeps
/// the two sides agreeing on the keys. Foundation only, for the same reason.
///
/// The glance itself **is** the widgets' ``WidgetSnapshot``. The watch shows the same
/// four things a Home Screen widget does — the next session, the weekly goal, the streak
/// and the race — so it takes the same finished strings from the same builder rather
/// than a second, watch-shaped payload that could drift from the first. What differs is
/// the transport: a watch is another device, so the App Group file cannot reach it, and
/// WatchConnectivity's application context carries the value instead. The system keeps
/// only the newest context and hands it to the watch app the next time it runs, which
/// is exactly the delivery a glance wants.
public struct WatchContext: Sendable, Equatable {

    public var snapshot: WidgetSnapshot

    /// The next session as a WorkoutKit plan, in `WorkoutPlan.dataRepresentation` form,
    /// or `nil` when there is nothing the watch could offer to start.
    ///
    /// Raw `Data` rather than a `WorkoutPlan` so this file stays free of WorkoutKit. The
    /// phone builds it with the same builder that schedules the plan in the Workout app
    /// (`HealthKitRepository.makeWorkoutPlan`), so a run started from Stride's watch app
    /// is the same structured workout, with the same pace alerts, as the scheduled one.
    ///
    /// **Only ever started on its own day.** A run recorded on the Watch is matched back to
    /// the plan by calendar day (`WorkoutSyncService.linkToScheduledWorkouts`), so starting
    /// an overdue Tuesday session on Thursday would record a run that fulfils Thursday — or
    /// nothing. The phone never sends an overdue one, and sends a future one ahead of its
    /// day so the Watch can start it without the phone app having run that morning (P2.2);
    /// ``canStart(asOf:calendar:)`` holds the button back until the day comes.
    public var startableWorkout: Data?

    /// The same session in Stride's own terms, for Stride's watch app to record itself
    /// (Watch runs). Sent under the same rules as ``startableWorkout``: never overdue,
    /// never a rest day or a finished session. A watch build from before this key ignores it.
    public var runSession: WatchRunSession?

    /// The runner's own workouts, most recently used first, for the watch to start without
    /// the phone (Custom workouts, PR 5). Each is a ``WatchRunSession`` whose `sessionID`
    /// is the ``SavedWorkout``'s id, so the run it records names the workout it followed.
    /// Capped at ``maxCustomWorkouts``: the application context is meant to be small.
    public var customWorkouts: [WatchRunSession]

    public static let maxCustomWorkouts = 10

    public init(
        snapshot: WidgetSnapshot,
        startableWorkout: Data? = nil,
        runSession: WatchRunSession? = nil,
        customWorkouts: [WatchRunSession] = []
    ) {
        self.snapshot = snapshot
        self.startableWorkout = startableWorkout
        self.runSession = runSession
        self.customWorkouts = Array(customWorkouts.prefix(Self.maxCustomWorkouts))
    }

    /// Whether the watch should offer to start ``startableWorkout`` at `now`.
    ///
    /// Checked at render time as well as when the phone builds the value: the watch can
    /// hold yesterday's context well past midnight if the phone app has not run since.
    public func canStart(asOf now: Date, calendar: Calendar = .current) -> Bool {
        guard startableWorkout != nil,
              let next = snapshot.nextWorkout,
              !next.isRest else { return false }
        return WidgetRelativeDay.dayDelta(for: next.scheduledDate, asOf: now, calendar: calendar) == 0
    }

    // MARK: Application context

    /// The dictionary keys. Property-list values only — `WCSession` rejects anything else
    /// — so the snapshot travels as encoded JSON `Data` rather than as a nested dictionary.
    public enum Key {
        public static let snapshot = "snapshot"
        public static let startableWorkout = "startableWorkout"
        public static let runSession = "runSession"
        public static let customWorkouts = "customWorkouts"
    }

    /// The form `WCSession.updateApplicationContext(_:)` takes.
    public func applicationContext() throws -> [String: Any] {
        var context: [String: Any] = [Key.snapshot: try Self.encoder.encode(snapshot)]
        if let startableWorkout {
            context[Key.startableWorkout] = startableWorkout
        }
        if let runSession {
            context[Key.runSession] = try Self.encoder.encode(runSession)
        }
        if !customWorkouts.isEmpty {
            context[Key.customWorkouts] = try Self.encoder.encode(customWorkouts)
        }
        return context
    }

    /// Reads a received application context. `nil` when there is no snapshot in it or it
    /// no longer decodes — the watch then shows its "open Stride on your iPhone" state
    /// rather than a half-read card. A run session that no longer decodes is dropped on
    /// its own: the glance and the Workout app's Start still work without it.
    public init?(applicationContext: [String: Any]) {
        guard let data = applicationContext[Key.snapshot] as? Data,
              let snapshot = try? Self.decoder.decode(WidgetSnapshot.self, from: data)
        else { return nil }
        let runSession = (applicationContext[Key.runSession] as? Data)
            .flatMap { try? Self.decoder.decode(WatchRunSession.self, from: $0) }
        // Like the run session, dropped on its own if it no longer decodes.
        let customWorkouts = (applicationContext[Key.customWorkouts] as? Data)
            .flatMap { try? Self.decoder.decode([WatchRunSession].self, from: $0) } ?? []
        self.init(
            snapshot: snapshot,
            startableWorkout: applicationContext[Key.startableWorkout] as? Data,
            runSession: runSession,
            customWorkouts: customWorkouts
        )
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
