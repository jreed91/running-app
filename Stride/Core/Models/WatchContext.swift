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
struct WatchContext: Sendable, Equatable {

    var snapshot: WidgetSnapshot

    /// Today's session as a WorkoutKit plan, in `WorkoutPlan.dataRepresentation` form,
    /// or `nil` when there is nothing the watch should offer to start.
    ///
    /// Raw `Data` rather than a `WorkoutPlan` so this file stays free of WorkoutKit. The
    /// phone builds it with the same builder that schedules the plan in the Workout app
    /// (`HealthKitRepository.makeWorkoutPlan`), so a run started from Stride's watch app
    /// is the same structured workout, with the same pace alerts, as the scheduled one.
    ///
    /// **Only ever today's session.** A run recorded on the Watch is matched back to the
    /// plan by calendar day (`WorkoutSyncService.linkToScheduledWorkouts`), so starting an
    /// overdue Tuesday session on Thursday would record a run that fulfils Thursday — or
    /// nothing. Offering Start only for today keeps the button honest about what it does.
    var startableWorkout: Data?

    init(snapshot: WidgetSnapshot, startableWorkout: Data? = nil) {
        self.snapshot = snapshot
        self.startableWorkout = startableWorkout
    }

    /// Whether the watch should offer to start ``startableWorkout`` at `now`.
    ///
    /// Checked at render time as well as when the phone builds the value: the watch can
    /// hold yesterday's context well past midnight if the phone app has not run since.
    func canStart(asOf now: Date, calendar: Calendar = .current) -> Bool {
        guard startableWorkout != nil,
              let next = snapshot.nextWorkout,
              !next.isRest else { return false }
        return WidgetRelativeDay.dayDelta(for: next.scheduledDate, asOf: now, calendar: calendar) == 0
    }

    // MARK: Application context

    /// The dictionary keys. Property-list values only — `WCSession` rejects anything else
    /// — so the snapshot travels as encoded JSON `Data` rather than as a nested dictionary.
    enum Key {
        static let snapshot = "snapshot"
        static let startableWorkout = "startableWorkout"
    }

    /// The form `WCSession.updateApplicationContext(_:)` takes.
    func applicationContext() throws -> [String: Any] {
        var context: [String: Any] = [Key.snapshot: try Self.encoder.encode(snapshot)]
        if let startableWorkout {
            context[Key.startableWorkout] = startableWorkout
        }
        return context
    }

    /// Reads a received application context. `nil` when there is no snapshot in it or it
    /// no longer decodes — the watch then shows its "open Stride on your iPhone" state
    /// rather than a half-read card.
    init?(applicationContext: [String: Any]) {
        guard let data = applicationContext[Key.snapshot] as? Data,
              let snapshot = try? Self.decoder.decode(WidgetSnapshot.self, from: data)
        else { return nil }
        self.init(
            snapshot: snapshot,
            startableWorkout: applicationContext[Key.startableWorkout] as? Data
        )
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
