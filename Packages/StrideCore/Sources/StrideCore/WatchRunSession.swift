import Foundation

// MARK: - WatchRunSession

/// Today's session as Stride's own watch app will run it (Watch runs, PR 1).
///
/// ``WatchContext/startableWorkout`` is a WorkoutKit plan, which only Apple's Workout app
/// can run. Recording in Stride's own watch app needs the session in Stride's own terms:
/// the ``WorkoutStructure`` that ``GuidedWorkoutState`` steps through, the pace band the
/// phone's HUD shows, and the max heart rate the zones are cut from. Nothing on the watch
/// reads this yet; the recorder in the next PR does.
///
/// Compiled into the app and `StrideWatch`, Foundation only, like ``WatchContext``. Sent as
/// Stride's own `Codable` rather than re-read from the WorkoutKit plan, so it does not
/// depend on a `WorkoutPlan` encoded on iOS 27 decoding on watchOS 26.
public struct WatchRunSession: Codable, Equatable, Sendable {

    /// The `ScheduledWorkout` id, so a run recorded on the watch can name the exact session
    /// it fulfils instead of being matched to the plan by day.
    public var sessionID: UUID
    public var scheduledDate: Date
    /// The session's name as the plan shows it, for example "Intervals".
    public var title: String
    public var targetDistanceMeters: Double?
    /// The pace band in seconds per kilometre, whatever the runner's display unit.
    public var targetPaceLowerSecondsPerKm: Double?
    public var targetPaceUpperSecondsPerKm: Double?
    /// `nil` for a run with no steps (an easy or long run).
    public var structure: WorkoutStructure?
    /// Run/walk plans call their steps "Run" and "Walk" rather than "Rep" and "Recover".
    public var usesRunWalkCues: Bool
    /// `nil` when the profile has neither a max heart rate nor an age, so no zones.
    public var maxHeartRateBPM: Int?
    public var usesMetricUnits: Bool
    /// Speak each kilometre or mile (Settings > Spoken splits). Optional so a context from
    /// a phone build before PR 4 still decodes; `nil` reads as off.
    public var speaksSplits: Bool?
    /// Speak each step of a structured session (Settings > Spoken workout steps).
    public var speaksSteps: Bool?

    public var unit: UnitPreference { usesMetricUnits ? .metric : .imperial }

    /// The session's pace band, for the split announcement's "on pace" verdict.
    public var targetPaceRange: ClosedRange<Double>? {
        guard let lower = targetPaceLowerSecondsPerKm, let upper = targetPaceUpperSecondsPerKm,
              lower > 0, lower <= upper else { return nil }
        return lower...upper
    }

    /// The guided stepper for this session, or `nil` for a run with no steps.
    public func guidedState() -> GuidedWorkoutState? {
        guard let structure, !structure.mainSets.isEmpty else { return nil }
        return GuidedWorkoutState(structure: structure, cueStyle: usesRunWalkCues ? .runWalk : .reps)
    }

    public init(
        sessionID: UUID,
        scheduledDate: Date,
        title: String,
        targetDistanceMeters: Double? = nil,
        targetPaceLowerSecondsPerKm: Double? = nil,
        targetPaceUpperSecondsPerKm: Double? = nil,
        structure: WorkoutStructure? = nil,
        usesRunWalkCues: Bool,
        maxHeartRateBPM: Int? = nil,
        usesMetricUnits: Bool,
        speaksSplits: Bool? = nil,
        speaksSteps: Bool? = nil
    ) {
        self.sessionID = sessionID
        self.scheduledDate = scheduledDate
        self.title = title
        self.targetDistanceMeters = targetDistanceMeters
        self.targetPaceLowerSecondsPerKm = targetPaceLowerSecondsPerKm
        self.targetPaceUpperSecondsPerKm = targetPaceUpperSecondsPerKm
        self.structure = structure
        self.usesRunWalkCues = usesRunWalkCues
        self.maxHeartRateBPM = maxHeartRateBPM
        self.usesMetricUnits = usesMetricUnits
        self.speaksSplits = speaksSplits
        self.speaksSteps = speaksSteps
    }
}
