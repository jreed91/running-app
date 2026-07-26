import Foundation
import Observation

// MARK: - ActiveRunPresentation

/// Where the active-run HUD is, and what its session has to remember while the HUD is
/// off screen.
///
/// The HUD used to be a `fullScreenCover` owned by `DashboardView`, which made "leave
/// this screen" and "end this run" the same act: Finish and Discard were the only ways
/// off it, so checking next week's plan or last week's mileage mid-run meant stopping
/// the run first (U7). It is presented by `MainTabView` now, so a run can be
/// *minimised* into `tabViewBottomAccessory` — the Now Playing pattern — and reopened
/// from there while the rest of the app stays reachable.
///
/// Two pieces of state have to outlive the cover for minimising to be lossless, and
/// neither can stay in the view, because dismissing a cover destroys it:
///
/// - the `ScheduledWorkout` the run fulfils, which decides the start type, the spoken
///   split's target band, and the plan day the saved run links back to (H4);
/// - the guided stepper's position, so reopening a structured session does not put a
///   runner three intervals in back on step 1.
///
/// `WorkoutTrackerService` owns everything else — distance, elapsed time, splits,
/// tracking state — and always did, which is why minimising needs no other bookkeeping:
/// the tracker never knew the HUD existed.
@MainActor
@Observable
final class ActiveRunPresentation {

    /// True while the full-screen HUD is on screen. False *with the tracker recording*
    /// is the minimised state, which is what the tab-bar accessory shows; false with
    /// nothing recording is no run at all.
    var isPresented = false

    /// The scheduled workout this run fulfils; `nil` for a free run.
    private(set) var scheduledWorkout: ScheduledWorkout?

    /// Guided structured-workout state, present only when the run fulfils a scheduled
    /// workout carrying a multi-segment `WorkoutStructure` (A4). `GuidedWorkoutBanner`
    /// advances it through a binding, so it cannot be `private(set)`.
    var guided: GuidedWorkoutState?

    // MARK: Lifecycle

    /// What a start control does: a run already underway is *reopened*, never replaced.
    ///
    /// The dashboard's start buttons stay tappable while a run is minimised — that is the
    /// cost of the run outliving its screen — and a runner tapping one then means "show
    /// me my run". Starting a second session over the top would discard the guided
    /// stepper's position and the plan day the recording run is linked to (H4), and leave
    /// the tracker recording a run the app had forgotten the context for.
    func startOrReopen(scheduledWorkout: ScheduledWorkout?, isRunInProgress: Bool) {
        guard !isRunInProgress else {
            reopen()
            return
        }
        start(scheduledWorkout: scheduledWorkout)
    }

    /// Opens the HUD for a new run, replacing whatever the last session left behind.
    func start(scheduledWorkout: ScheduledWorkout?) {
        self.scheduledWorkout = scheduledWorkout
        // Built here rather than in the HUD's `onAppear`, which now runs again on every
        // reopen and would restart the stepper each time.
        if let structure = scheduledWorkout?.workoutStructure, !structure.mainSets.isEmpty {
            guided = GuidedWorkoutState(structure: structure)
        } else {
            guided = nil
        }
        isPresented = true
    }

    /// Hides the HUD and keeps the session: the tracker goes on recording and the
    /// tab-bar accessory takes over.
    func minimize() {
        isPresented = false
    }

    /// Brings the HUD back from the accessory.
    func reopen() {
        isPresented = true
    }

    /// Ends the session — the run has been saved, discarded, or closed before it began.
    /// Clearing the session is what stops a finished run's scheduled workout from
    /// leaking into the next one started from the free-run button.
    ///
    /// Called from the HUD's `onDisappear` rather than from the finish/discard actions
    /// themselves: the HUD is still on screen while the cover slides away, and clearing
    /// the session under it would pop the guided banner and its Step cell out a frame
    /// before the screen went.
    func end() {
        isPresented = false
        scheduledWorkout = nil
        guided = nil
    }
}
