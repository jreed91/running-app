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

    /// The runner's own workout this run follows, when it was started from My workouts
    /// (Custom workouts, PR 3). A copy of its name and structure rather than the
    /// `SavedWorkout` itself, so editing or deleting it mid-run changes nothing here.
    struct CustomRun: Equatable, Sendable {
        let id: UUID
        let name: String
        let structure: WorkoutStructure
    }

    /// `nil` unless the run was started from My workouts. Never set together with
    /// ``scheduledWorkout``.
    private(set) var customRun: CustomRun?

    /// Guided structured-workout state, present only when the run fulfils a scheduled
    /// workout carrying a multi-segment `WorkoutStructure` (A4), or follows a custom one. `GuidedWorkoutBanner`
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

    /// ``startOrReopen(scheduledWorkout:isRunInProgress:)`` for one of the runner's own
    /// workouts: a run already underway is reopened, never replaced.
    func startOrReopen(customRun: CustomRun, isRunInProgress: Bool) {
        guard !isRunInProgress else {
            reopen()
            return
        }
        start(customRun: customRun)
    }

    /// Opens the HUD for a run that follows one of the runner's own workouts. It fulfils
    /// no plan day here; a run on a plan day can still complete it later through the same
    /// day match every free run gets.
    func start(customRun: CustomRun) {
        scheduledWorkout = nil
        self.customRun = customRun
        guided = customRun.structure.mainSets.isEmpty ? nil : GuidedWorkoutState(structure: customRun.structure)
        isPresented = true
    }

    /// Opens the HUD for a new run, replacing whatever the last session left behind.
    func start(scheduledWorkout: ScheduledWorkout?) {
        self.scheduledWorkout = scheduledWorkout
        customRun = nil
        // Built here rather than in the HUD's `onAppear`, which now runs again on every
        // reopen and would restart the stepper each time.
        if let scheduledWorkout, let structure = scheduledWorkout.workoutStructure, !structure.mainSets.isEmpty {
            guided = GuidedWorkoutState(structure: structure, cueStyle: Self.cueStyle(for: scheduledWorkout))
        } else {
            guided = nil
        }
        isPresented = true
    }

    /// Run/walk words for a run from a plan prescribed in minutes (Start Running, pregnancy):
    /// its sessions are runs with walks between them, and its segments are named that way.
    /// Everything else is called as reps.
    static func cueStyle(for workout: ScheduledWorkout) -> GuidedCueStyle {
        guard workout.workoutType.isRunType,
              workout.week?.plan?.planKind.prescribesByTime == true else { return .reps }
        return .runWalk
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
        customRun = nil
        guided = nil
    }
}
