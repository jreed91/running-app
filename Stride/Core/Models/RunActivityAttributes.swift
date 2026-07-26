import ActivityKit
import Foundation

// MARK: - RunActivityAttributes

/// The Live Activity for a run in progress (U5b).
///
/// Compiled into **both** the app and `StrideWidgets`: ActivityKit matches the two sides
/// on the type itself, so this file is listed in both targets' sources rather than
/// duplicated. Keep it free of anything app-only — no SwiftData, no services, no theme —
/// or the widget extension stops building.
///
/// The content state carries **preformatted strings** rather than raw metres and seconds.
/// The app owns unit preference and every formatter in this repo, so shipping "5.4 km"
/// instead of `5400` keeps the widget from needing either, and keeps the Lock Screen
/// agreeing with the HUD by construction rather than by two implementations happening to
/// round the same way.
struct RunActivityAttributes: ActivityAttributes {

    /// Everything that changes while the run is going.
    struct ContentState: Codable, Hashable {

        /// Distance so far, in the runner's own unit — "5.4 km", "3.4 mi".
        var distance: String

        /// Current pace in the runner's own unit — "4:32 /km" — or `nil` before the first
        /// reading, which is most of the first minute of a run.
        var pace: String?

        /// The interval the widget renders its own ticking clock over, via
        /// `Text(timerInterval:pauseTime:countsDown:)`.
        ///
        /// Pushing one update per second would spend the activity's update budget on a
        /// number the system can count by itself — and would keep spending it while the
        /// phone is locked in a pocket, which is the whole case this exists for.
        var elapsed: ClosedRange<Date>

        /// Freezes that clock where it stands, and is what the widget keys "Paused" off.
        var pausedAt: Date?

        var isPaused: Bool { pausedAt != nil }
    }

    /// What the run is — "Tempo", "Long Run" — fixed for the activity's lifetime.
    var workoutName: String

    /// When the run started, for anything that wants to date it rather than count it.
    var startedAt: Date
}

// MARK: - RunActivityDeepLink

/// The link the run's Live Activity carries, so tapping the card lands on the run rather
/// than merely foregrounding the app.
///
/// Shared for the same reason the attributes are: the widget builds this URL and the app
/// resolves it, and two hand-written copies of a scheme in two targets is exactly how a
/// deep link rots without anything failing to compile.
enum RunActivityDeepLink {
    static let scheme = "stride"
    static let activeRunHost = "active-run"

    /// `stride://active-run` — reopens the run HUD (U7's minimised run is otherwise only
    /// reachable from the tab-bar accessory).
    static var activeRun: URL? {
        URL(string: "\(scheme)://\(activeRunHost)")
    }
}
