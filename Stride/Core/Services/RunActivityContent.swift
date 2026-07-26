import ActivityKit
import Foundation

// MARK: - RunActivitySnapshot

/// A run's live state at one instant, as the Live Activity needs it.
///
/// The tracker hands these out rather than handing out itself: it keeps ActivityKit and
/// the unit-formatting rules on the other side of a plain value, and it makes the mapping
/// below testable without a running workout.
struct RunActivitySnapshot: Equatable, Sendable {
    var elapsedSeconds: Double
    var distanceMeters: Double
    var paceSecondsPerKm: Double
    var isPaused: Bool
    var unit: UnitPreference
    var workoutType: WorkoutType
}

// MARK: - RunActivityContent

/// Turns a run snapshot into what the Lock Screen shows (U5b).
///
/// Pure, so the two things that are easy to get wrong here are pinned by tests: the
/// elapsed *interval* the widget counts over — derived backwards from the run's elapsed
/// time, because the activity may be started or refreshed mid-run — and the paused case,
/// where that interval has to freeze at exactly the elapsed time rather than at zero.
enum RunActivityContent {

    /// How long an interval the widget's clock is given. It only bounds the ticking
    /// display, so it needs to outlast any plausible run rather than be accurate.
    static let clockSpan: TimeInterval = 24 * 60 * 60

    /// How stale content is allowed to get before the system dims it — long enough that a
    /// normal refresh cadence never trips it, short enough that a killed app stops showing
    /// a run that is no longer being recorded.
    static let staleAfter: TimeInterval = 90

    static func state(
        from snapshot: RunActivitySnapshot,
        now: Date = Date()
    ) -> RunActivityAttributes.ContentState {
        // The run did not necessarily start when the activity did — a refresh happens
        // mid-run, and a resumed run has banked time — so the clock's start is derived
        // from elapsed time rather than remembered.
        let start = now.addingTimeInterval(-snapshot.elapsedSeconds)
        return RunActivityAttributes.ContentState(
            distance: snapshot.distanceMeters.distanceString(unit: snapshot.unit),
            // Below the first fix the tracker reports 0, which the pace formatters render
            // as a placeholder. An absent pace is more honest on a Lock Screen than
            // "--:-- /km". Formatted the way the run HUD's pace cell is — value plus a
            // short unit — rather than as `paceString`'s "4:32 min/km", which repeats the
            // card's own "Pace" label.
            pace: snapshot.paceSecondsPerKm > 0
                ? snapshot.paceSecondsPerKm.paceValueString(unit: snapshot.unit)
                    + " " + paceUnitLabel(snapshot.unit)
                : nil,
            elapsed: start...start.addingTimeInterval(clockSpan),
            pausedAt: snapshot.isPaused ? now : nil
        )
    }

    static func staleDate(from now: Date = Date()) -> Date {
        now.addingTimeInterval(staleAfter)
    }

    private static func paceUnitLabel(_ unit: UnitPreference) -> String {
        switch unit {
        case .metric:   return "/km"
        case .imperial: return "/mi"
        }
    }
}
