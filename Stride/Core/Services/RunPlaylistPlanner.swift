import Foundation

/// Turns a scheduled session into the *shape* of a playlist: an ordered run of blocks, each
/// with an energy and a length.
///
/// Pure, and that is the point. Everything interesting about this feature — which parts of a
/// session are hard, how an interval ladder collapses into something a playlist can actually
/// play, what happens to a pregnancy session — is decided here, where it can be tested
/// without MusicKit, a subscription, a network or a device. ``RunPlaylistService`` holds only
/// the plumbing: authorization, track sourcing, and the write into the runner's library.
enum RunPlaylistPlanner {

    /// The parts of a `ScheduledWorkout` a plan is derived from.
    ///
    /// A value type rather than the model, so the planner never touches SwiftData and a test
    /// can describe a session in three lines.
    struct Session: Sendable {
        var workoutType: WorkoutType
        /// Whether the owning plan is a pregnancy plan. See ``workEnergy(for:isPregnancy:)``
        /// for why this is asked rather than inferred from the session.
        var isPregnancyPlan: Bool
        var structure: WorkoutStructure?
        var targetDistanceMeters: Double?
        /// Midpoint of the session's target pace band, in seconds per kilometre. Nil for any
        /// session prescribed by effort rather than pace — every pregnancy session, for one.
        var targetPaceSecondsPerKm: Double?

        init(
            workoutType: WorkoutType,
            isPregnancyPlan: Bool = false,
            structure: WorkoutStructure? = nil,
            targetDistanceMeters: Double? = nil,
            targetPaceSecondsPerKm: Double? = nil
        ) {
            self.workoutType = workoutType
            self.isPregnancyPlan = isPregnancyPlan
            self.structure = structure
            self.targetDistanceMeters = targetDistanceMeters
            self.targetPaceSecondsPerKm = targetPaceSecondsPerKm
        }
    }

    // MARK: - Entry point

    /// The playlist shape for a session, or `nil` when there is nothing to score.
    ///
    /// Returns `nil` for anything that is not a run — a rest day, a strength session, a
    /// cross-training day, an imported walk — and for a run whose duration cannot be
    /// estimated at all, because a playlist of unknown length is not a playlist.
    static func plan(for session: Session) -> RunPlaylistPlan? {
        guard session.workoutType.isRunType else { return nil }

        var blocks = rawTimeline(for: session)
        if blocks.isEmpty {
            guard let total = fallbackSeconds(for: session), total > 0 else { return nil }
            blocks = [WorkingBlock(energy: workEnergy(for: session), seconds: total)]
        }

        blocks = coalesce(blocks)
        blocks = absorbShortBlocks(blocks)
        blocks = capBlockCount(blocks)

        guard !blocks.isEmpty else { return nil }
        let finished = blocks.map { RunPlaylistBlock(energy: $0.energy, seconds: $0.seconds) }
        return RunPlaylistPlan(blocks: finished, sessionSeconds: finished.reduce(0) { $0 + $1.seconds })
    }

    // MARK: - Working block

    /// A block mid-smoothing, which remembers what it was built out of.
    ///
    /// The contributions are the whole reason this type exists rather than smoothing
    /// `RunPlaylistBlock` directly. Merging by "take the neighbour's energy" reads fine until
    /// you trace 10 × 400 m: the first rep's nearest long neighbour is the fifteen-minute
    /// warm-up, so the interval body gets eaten a rep at a time and the session comes out as
    /// one calm block. Keeping a tally of which energy contributed which seconds means a
    /// merged block is named for what most of it *is*, which for that session is the
    /// intervals — and it is what lets a long recovery jog inside a set still register as
    /// steady rather than being silently relabelled.
    private struct WorkingBlock {
        var seconds: Double
        var contributions: [RunPlaylistEnergy: Double]

        init(energy: RunPlaylistEnergy, seconds: Double) {
            self.seconds = seconds
            self.contributions = [energy: seconds]
        }

        /// The energy that accounts for most of this block.
        ///
        /// A tie goes to the harder energy — `RunPlaylistEnergy.allCases` runs calm → steady
        /// → hard, and `>=` lets the later case win. An interval and its equal-length
        /// recovery should read as interval: the work is what the runner is there for.
        var energy: RunPlaylistEnergy {
            var best = (energy: RunPlaylistEnergy.calm, seconds: -1.0)
            for candidate in RunPlaylistEnergy.allCases {
                let value = contributions[candidate] ?? 0
                if value >= best.seconds { best = (energy: candidate, seconds: value) }
            }
            return best.energy
        }

        var isShort: Bool { seconds < MusicEnergyPolicy.minimumBlockSeconds }

        mutating func absorb(_ other: WorkingBlock) {
            seconds += other.seconds
            for (energy, value) in other.contributions {
                contributions[energy, default: 0] += value
            }
        }
    }

    // MARK: - Energy mapping

    /// The energy of the working part of a session.
    ///
    /// **Pregnancy sessions are capped at `.steady`**, and the cap is asked of the plan
    /// rather than read off the session. A pregnancy plan carries its moderate day as
    /// `WorkoutType.tempo` — the type is what the rest of the app renders — so mapping by
    /// type alone would score it `.hard`, which is precisely the reading a pregnancy plan
    /// spends its whole design avoiding. Its ceiling is "you can talk but not sing"; the
    /// music's ceiling matches. That also means the moderate day and the easy day get the
    /// same shape, which is honest: the difference between them is effort, and Stride does
    /// not claim a playlist changes effort.
    static func workEnergy(for type: WorkoutType, isPregnancy: Bool) -> RunPlaylistEnergy {
        guard !isPregnancy else { return .steady }
        switch type {
        case .tempo, .interval, .race: return .hard
        case .easy, .longRun:          return .steady
        default:                       return .steady
        }
    }

    /// The energy of a recovery jog between reps, and of a warm-up or cool-down.
    ///
    /// A recovery jog inside an interval set is `.steady`, not `.calm`: the runner is still
    /// moving, and dropping to ambient between 400s would be a worse read of the session
    /// than staying with it.
    static func recoveryEnergy(for type: WorkoutType, isPregnancy: Bool) -> RunPlaylistEnergy {
        guard !isPregnancy else { return .calm }
        switch type {
        case .tempo, .interval, .race: return .steady
        default:                       return .calm
        }
    }

    private static func workEnergy(for session: Session) -> RunPlaylistEnergy {
        workEnergy(for: session.workoutType, isPregnancy: session.isPregnancyPlan)
    }

    private static func recoveryEnergy(for session: Session) -> RunPlaylistEnergy {
        recoveryEnergy(for: session.workoutType, isPregnancy: session.isPregnancyPlan)
    }

    // MARK: - Naming

    /// The name the playlist is given in the runner's Apple Music library.
    ///
    /// Prefixed so a runner scrolling their library knows where it came from, and dated so
    /// the playlists for Tuesday's and Thursday's tempo runs are told apart. Built outside a
    /// view, so it says `String(localized:)` explicitly — the compiler extracts nothing from
    /// a bare literal in a `-> String`.
    static func playlistName(
        for type: WorkoutType,
        date: Date,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        let day = formatter.string(from: date)
        return String(
            localized: "Stride · \(type.localizedName) · \(day)",
            comment: "Name of a generated Apple Music playlist: app name, workout type, date"
        )
    }

    /// The description written onto the playlist, which Apple Music shows under its name.
    static func playlistDescription(for plan: RunPlaylistPlan) -> String {
        let minutes = Int((plan.sessionSeconds / 60).rounded())
        return String(
            localized: "Built by Stride for a \(minutes)-minute session.",
            comment: "Description attached to a generated Apple Music playlist"
        )
    }

    // MARK: - Timeline

    /// Expands a session's structure into one block per segment, before any smoothing.
    private static func rawTimeline(for session: Session) -> [WorkingBlock] {
        guard let structure = session.structure else { return [] }

        let work = workEnergy(for: session)
        let recovery = recoveryEnergy(for: session)
        var blocks: [WorkingBlock] = []

        if let warmup = seconds(of: structure.warmup, session: session), warmup > 0 {
            blocks.append(WorkingBlock(energy: .calm, seconds: warmup))
        }

        for set in structure.mainSets {
            let reps = max(1, set.repetitions)
            let workSeconds = seconds(of: set.workSegment, session: session) ?? 0
            let recoverySeconds = seconds(of: set.recoverySegment, session: session) ?? 0

            for rep in 0..<reps {
                if workSeconds > 0 {
                    blocks.append(WorkingBlock(energy: work, seconds: workSeconds))
                }
                // There are only `reps - 1` recovery jogs: the last rep is followed by the
                // cool-down, not another recovery. `WorkoutSet.totalRecoverySeconds` counts
                // them the same way.
                if rep < reps - 1, recoverySeconds > 0 {
                    blocks.append(WorkingBlock(energy: recovery, seconds: recoverySeconds))
                }
            }
        }

        if let cooldown = seconds(of: structure.cooldown, session: session), cooldown > 0 {
            blocks.append(WorkingBlock(energy: .calm, seconds: cooldown))
        }

        return blocks
    }

    /// How long a segment lasts.
    ///
    /// A segment carries either a duration or a distance. A distance is converted with the
    /// segment's own pace where it has one, and otherwise with the session's — a structured
    /// workout's warm-up commonly states metres and leaves the pace to the prescription.
    private static func seconds(of segment: WorkoutSegment, session: Session) -> Double? {
        if let duration = segment.durationSeconds, duration > 0 { return duration }
        guard let meters = segment.distanceMeters, meters > 0 else { return nil }
        guard let pace = segment.targetPaceSecondsPerKm ?? session.targetPaceSecondsPerKm, pace > 0 else {
            return nil
        }
        return meters / 1_000 * pace
    }

    /// Duration for a session with no structure at all — most easy days.
    private static func fallbackSeconds(for session: Session) -> Double? {
        if let total = session.structure?.totalEstimatedDurationSeconds, total > 0 { return total }
        guard let meters = session.targetDistanceMeters, meters > 0,
              let pace = session.targetPaceSecondsPerKm, pace > 0 else { return nil }
        return meters / 1_000 * pace
    }

    // MARK: - Smoothing

    /// Merges neighbouring blocks that share an energy.
    private static func coalesce(_ blocks: [WorkingBlock]) -> [WorkingBlock] {
        blocks.reduce(into: [WorkingBlock]()) { result, block in
            if let last = result.last, last.energy == block.energy {
                result[result.count - 1].absorb(block)
            } else {
                result.append(block)
            }
        }
    }

    /// Folds away any block too short to be worth its own stretch of music.
    ///
    /// This is what turns 10 × 400 m off 90-second jogs — twenty alternating segments, none
    /// of them long enough to hold a track and a half — into one hard block, without the
    /// warm-up either swallowing it or being swallowed by it. Warm-ups and cool-downs
    /// normally survive as their own blocks, because they are normally long enough.
    private static func absorbShortBlocks(_ blocks: [WorkingBlock]) -> [WorkingBlock] {
        var result = blocks
        while result.count > 1,
              let index = indexOfShortestBlock(in: result),
              result[index].isShort {
            result = coalesce(mergeBlock(at: index, in: result))
        }
        return result
    }

    /// Merges shortest-first until the plan is down to ``MusicEnergyPolicy/maximumBlockCount``.
    private static func capBlockCount(_ blocks: [WorkingBlock]) -> [WorkingBlock] {
        var result = blocks
        while result.count > MusicEnergyPolicy.maximumBlockCount,
              let index = indexOfShortestBlock(in: result) {
            result = coalesce(mergeBlock(at: index, in: result))
        }
        return result
    }

    private static func indexOfShortestBlock(in blocks: [WorkingBlock]) -> Int? {
        blocks.indices.min { blocks[$0].seconds < blocks[$1].seconds }
    }

    /// Absorbs the block at `index` into one of its neighbours.
    ///
    /// **A short neighbour is preferred to a long one**, and that preference is what keeps a
    /// repeating body from bleeding into its bookends. Merging the first 400 m rep into the
    /// fifteen-minute warm-up beside it — the "longer neighbour" — is how the whole interval
    /// block used to disappear a rep at a time; merging it into the 90-second jog on its
    /// other side keeps the body folding into itself until it is one block that is mostly
    /// interval, which is what it is.
    ///
    /// Between two equally suitable neighbours the longer one wins, and a tie there goes to
    /// the harder one. The merged block's energy is not decided here at all — it falls out of
    /// ``WorkingBlock/energy`` once the contributions are pooled.
    private static func mergeBlock(at index: Int, in blocks: [WorkingBlock]) -> [WorkingBlock] {
        guard blocks.count > 1, blocks.indices.contains(index) else { return blocks }

        let previous = index > 0 ? index - 1 : nil
        let next = index < blocks.count - 1 ? index + 1 : nil

        let target: Int
        switch (previous, next) {
        case let (.some(p), .some(n)):
            if blocks[p].isShort != blocks[n].isShort {
                target = blocks[p].isShort ? p : n
            } else if blocks[p].seconds != blocks[n].seconds {
                target = blocks[p].seconds > blocks[n].seconds ? p : n
            } else {
                target = rank(blocks[p].energy) >= rank(blocks[n].energy) ? p : n
            }
        case let (.some(p), .none):
            target = p
        case let (.none, .some(n)):
            target = n
        case (.none, .none):
            return blocks
        }

        var result = blocks
        result[target].absorb(result[index])
        result.remove(at: index)
        return result
    }

    /// Calm < steady < hard, which is the order `RunPlaylistEnergy` declares its cases in.
    private static func rank(_ energy: RunPlaylistEnergy) -> Int {
        RunPlaylistEnergy.allCases.firstIndex(of: energy) ?? 0
    }
}

// MARK: - Model bridge

extension RunPlaylistPlanner.Session {

    /// Reads a persisted session into the planner's value type.
    ///
    /// The pace midpoint is nil whenever the session has no band, which is every pregnancy
    /// session by design — `PregnancyPlanService` leaves both bounds nil because pregnancy
    /// moves the pace–effort relationship week by week. Nothing here writes a pace back.
    @MainActor
    init(workout: ScheduledWorkout) {
        let band = workout.targetPaceRange
        self.init(
            workoutType: workout.workoutType,
            isPregnancyPlan: workout.week?.plan?.isPregnancyPlan ?? false,
            structure: workout.workoutStructure,
            targetDistanceMeters: workout.targetDistanceMeters,
            targetPaceSecondsPerKm: band.map { ($0.lowerBound + $0.upperBound) / 2 }
        )
    }
}
