import Foundation

// MARK: - StrengthSessionCheckpoint

/// A strength session in progress, saved after every set so closing the app, a crash or
/// a phone call doesn't lose it.
///
/// Runs have had this since P1.2 (`RunCheckpoint`); a strength session lived only in the
/// view's state, so twenty minutes of sets disappeared with the process. One checkpoint
/// at a time, in `UserDefaults`: it is small (sets and positions), device-local, and
/// only ever read back by the session screen.
struct StrengthSessionCheckpoint: Codable, Equatable, Sendable {
    /// The scheduled session being done, or nil for an unplanned one.
    let scheduledWorkoutID: UUID?
    /// The exercises as planned, so an unplanned session can be rebuilt as it was.
    let plan: StrengthWorkoutPlan
    /// Swapped exercises by position, as on the session screen.
    let swaps: [Int: StrengthExercise]
    let completedSets: [CompletedStrengthSet]
    let currentExerciseIndex: Int
    let currentSetIndex: Int
    let startTime: Date
    let savedAt: Date

    /// Older than this, a checkpoint is a session abandoned, not one interrupted.
    static let resumableForSeconds: TimeInterval = 6 * 3_600

    static let defaultsKey = "strength.sessionCheckpoint"

    /// Whether this checkpoint is the session about to open: the same scheduled session,
    /// or both unplanned; recent enough; and with a set actually done.
    func resumes(scheduledWorkoutID id: UUID?, now: Date = Date()) -> Bool {
        id == scheduledWorkoutID
            && now.timeIntervalSince(savedAt) <= Self.resumableForSeconds
            && now >= savedAt.addingTimeInterval(-60)
            && completedSets.contains { !$0.skipped }
    }

    // MARK: Storage

    static func load(from defaults: UserDefaults = .standard) -> StrengthSessionCheckpoint? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(StrengthSessionCheckpoint.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
