import Foundation

// MARK: - RunEffortPolicy

/// The one definition of "this is a real run, not a mis-tap".
///
/// Two paths need the same floor and used to have only one of them: the importer
/// rejected tiny HealthKit shells, while a run recorded in the app was saved,
/// exported, linked to its scheduled day, and fed into pace refresh and the streak
/// no matter how short it was (N17). Both now ask this type.
///
/// A genuine session has both a real distance **and** a non-trivial duration; a
/// 0 m / 30-second entry is noise that pollutes pace and VDOT stats.
enum RunEffortPolicy {

    /// Distance a run must exceed, in metres.
    static let minimumDistanceMeters: Double = 100

    /// Duration a run must reach, in seconds.
    static let minimumDurationSeconds: Double = 30

    /// Whether a run of this size counts as a real session.
    static func isRealRun(distanceMeters: Double, durationSeconds: Double) -> Bool {
        distanceMeters > minimumDistanceMeters && durationSeconds >= minimumDurationSeconds
    }

    /// Whether a finished run should be allowed to complete the scheduled day it was
    /// started from. A run that doesn't clear the floor is still saved — the runner
    /// can see and delete it — but it must not mark a planned workout done.
    static func canCompleteScheduledWorkout(_ workout: RunWorkout) -> Bool {
        isRealRun(distanceMeters: workout.distanceMeters, durationSeconds: workout.durationSeconds)
    }
}
