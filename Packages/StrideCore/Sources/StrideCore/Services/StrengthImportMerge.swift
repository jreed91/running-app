import Foundation

// MARK: - StrengthImportMerge

/// How strength workouts read from Apple Health join the sessions Stride already has.
///
/// A gym session can reach Health more than once. Stride writes its own copy of every
/// session logged here (N14), and a runner who also starts the Workout app on the Watch
/// for the rings, or lifts with an app such as Fitbod that writes to Health too, puts a
/// second recording of the same hour beside it. Each is its own HealthKit workout with its
/// own UUID, so the UUID alone kept none of them out: the Watch's copy came in as a second
/// session, the Progress card counted the hour twice, and the coach read an empty session
/// as the latest one.
///
/// Pure over ``Session`` values so the rules run in a test without SwiftData or HealthKit.
public enum StrengthImportMerge {

    /// A strength session as these rules read it: stored in Stride, or read from Health.
    public struct Session: Equatable, Sendable {
        /// The Stride session's id. For a workout read from Health this is the
        /// `StrideWorkoutID` in its metadata when Stride wrote it, and a fresh id otherwise.
        public let id: UUID
        public var healthKitWorkoutID: String?
        public let start: Date
        public let durationSeconds: Double

        public init(
            id: UUID,
            healthKitWorkoutID: String? = nil,
            start: Date,
            durationSeconds: Double
        ) {
            self.id = id
            self.healthKitWorkoutID = healthKitWorkoutID
            self.start = start
            self.durationSeconds = durationSeconds
        }
    }

    public enum Decision: Equatable, Sendable {
        /// A session Stride doesn't have yet: insert it.
        case insert
        /// Another recording of a stored session that has no HealthKit id yet: stamp the
        /// workout's id onto that session (the stored session's id) instead of inserting.
        case link(UUID)
        /// Another recording of a session Stride already has, linked to its own workout:
        /// drop it, and tombstone it so later passes don't read it again.
        case duplicate
    }

    /// Share of the shorter session two must overlap by to be one session recorded twice.
    /// Half, as for runs (`WorkoutSyncService.sameRecordingOverlapShare`): a Watch started a
    /// few minutes into the session or stopped a few minutes early is still the same hour,
    /// and two separate sessions never share half their time.
    public static let sameSessionOverlapShare = 0.5

    /// What to do with each workout in `imported`, keyed by its HealthKit id.
    ///
    /// In order: Stride's own export of a stored session links to it; a workout recorded
    /// over the same time as a stored session links to it when that session has no
    /// HealthKit id yet, and is a duplicate when it has one; of two imports recorded over
    /// the same time, the longer is kept. Everything else is inserted.
    public static func decisions(imported: [Session], stored: [Session]) -> [String: Decision] {
        var stored = stored
        var kept: [Session] = []
        var result: [String: Decision] = [:]

        // Longest first, so of two recordings of one session the fuller one is kept.
        let ordered = imported.sorted { lhs, rhs in
            if lhs.durationSeconds != rhs.durationSeconds { return lhs.durationSeconds > rhs.durationSeconds }
            return lhs.start < rhs.start
        }

        for workout in ordered {
            guard let hkID = workout.healthKitWorkoutID, result[hkID] == nil else { continue }

            if let index = stored.firstIndex(where: { $0.id == workout.id }) {
                result[hkID] = claim(&stored[index], with: hkID)
                continue
            }

            let sameTime = stored.indices.filter { isSameSession(workout, stored[$0]) }
            if let index = sameTime.first(where: { stored[$0].healthKitWorkoutID == nil }) ?? sameTime.first {
                result[hkID] = claim(&stored[index], with: hkID)
                continue
            }

            if kept.contains(where: { isSameSession(workout, $0) }) {
                result[hkID] = .duplicate
                continue
            }

            kept.append(workout)
            result[hkID] = .insert
        }
        return result
    }

    /// Whether two sessions are one session recorded twice: their time ranges overlap by
    /// at least ``sameSessionOverlapShare`` of the shorter one.
    public static func isSameSession(_ lhs: Session, _ rhs: Session) -> Bool {
        let lhsEnd = lhs.start.addingTimeInterval(max(lhs.durationSeconds, 0))
        let rhsEnd = rhs.start.addingTimeInterval(max(rhs.durationSeconds, 0))
        let overlap = min(lhsEnd, rhsEnd).timeIntervalSince(max(lhs.start, rhs.start))
        let shorter = min(lhs.durationSeconds, rhs.durationSeconds)
        guard overlap > 0, shorter > 0 else { return false }
        return overlap >= shorter * sameSessionOverlapShare
    }

    /// Links `hkID` to a stored session with no HealthKit id yet, or calls it a duplicate
    /// of one that has its own.
    private static func claim(_ session: inout Session, with hkID: String) -> Decision {
        guard session.healthKitWorkoutID == nil else { return .duplicate }
        session.healthKitWorkoutID = hkID
        return .link(session.id)
    }
}
