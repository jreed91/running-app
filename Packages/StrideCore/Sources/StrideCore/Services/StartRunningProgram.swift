import Foundation

// MARK: - StartRunningProgram

/// The Start Running progression: ten one-week stages, from one minute of running at a time
/// to thirty minutes without a break.
///
/// Every number a Start Running plan prescribes lives here, so the generator, the Plan tab
/// card and the tests all read one table. Why the table looks the way it does, and what it
/// was checked against, is in `docs/START_RUNNING_PROGRAM.md`. Read that before changing a
/// number, and update it in the same change.
///
/// The shape, in one line: the same session on every run day of a week, three run days a
/// week with a day between them, and each stage lengthens the longest stretch of running by
/// about half while the walk breaks stay at ninety seconds.
enum StartRunningProgram {

    // MARK: Stage

    /// One week of the program. Every run day of that week is this session.
    struct Stage: Hashable, Sendable {
        /// 1-based, `1...StartRunningProgram.stageCount`.
        let number: Int
        /// How many times the run (and the walk after it) repeats.
        let repetitions: Int
        /// The length of each stretch of running.
        let runSeconds: Int
        /// The walk between two runs. Zero for a continuous run. There is no walk after the
        /// last run: the cool-down walk follows it.
        let walkSeconds: Int

        var isContinuous: Bool { repetitions == 1 && walkSeconds == 0 }

        /// Time spent running in the main set.
        var runningSeconds: Int { repetitions * runSeconds }

        /// Time spent walking *between* runs, not counting the warm-up and cool-down.
        var walkBreakSeconds: Int { max(0, repetitions - 1) * walkSeconds }

        /// The main set, warm-up and cool-down not included.
        var mainSetSeconds: Int { runningSeconds + walkBreakSeconds }

        /// The whole session, warm-up and cool-down included.
        var sessionSeconds: Int {
            StartRunningProgram.warmupSeconds + mainSetSeconds + StartRunningProgram.cooldownSeconds
        }

        /// Whether this is the stage the program ends on.
        var isGraduation: Bool { number == StartRunningProgram.stageCount }

        /// "Run 2 min, walk 1:30, 6 times" or "Run 18 min without stopping".
        var summary: String {
            if isContinuous {
                return String(
                    localized: "Run \(StartRunningProgram.clock(runSeconds)) without stopping",
                    comment: "Start Running stage summary for a continuous run, e.g. 'Run 18 min without stopping'"
                )
            }
            return String(
                localized: """
                    Run \(StartRunningProgram.clock(runSeconds)), walk \
                    \(StartRunningProgram.clock(walkSeconds)), \(repetitions) times
                    """,
                comment: "Start Running stage summary for run/walk, e.g. 'Run 2 min, walk 1:30, 6 times'"
            )
        }
    }

    // MARK: The table

    /// The ten stages. The longest stretch of running goes 1, 1.5, 2, 3, 5, 8, 12, 18, 24
    /// and 30 minutes: never more than a 1.7× step. The NHS Couch to 5K schedule, which
    /// starts and ends in the same place, goes from 8 minutes of running at a time to 20
    /// within its fifth week; that step is the one this table was built to smooth out.
    static let stages: [Stage] = [
        Stage(number: 1, repetitions: 8, runSeconds: 60, walkSeconds: 90),
        Stage(number: 2, repetitions: 7, runSeconds: 90, walkSeconds: 90),
        Stage(number: 3, repetitions: 6, runSeconds: 120, walkSeconds: 90),
        Stage(number: 4, repetitions: 5, runSeconds: 180, walkSeconds: 90),
        Stage(number: 5, repetitions: 4, runSeconds: 300, walkSeconds: 90),
        Stage(number: 6, repetitions: 3, runSeconds: 480, walkSeconds: 90),
        Stage(number: 7, repetitions: 2, runSeconds: 720, walkSeconds: 90),
        Stage(number: 8, repetitions: 1, runSeconds: 1_080, walkSeconds: 0),
        Stage(number: 9, repetitions: 1, runSeconds: 1_440, walkSeconds: 0),
        Stage(number: 10, repetitions: 1, runSeconds: 1_800, walkSeconds: 0)
    ]

    static var stageCount: Int { stages.count }

    /// A brisk walk before every session.
    static let warmupSeconds = 5 * 60

    /// An easy walk after every session.
    static let cooldownSeconds = 5 * 60

    /// Run days a week. More than three days a runner offers are thinned to three, spaced
    /// as far apart as the chosen days allow, so there is a day between runs wherever the
    /// week has room for one.
    static let runsPerWeek = 3

    /// The stage numbered `number`, clamped into the table.
    static func stage(_ number: Int) -> Stage {
        stages[min(max(number, 1), stageCount) - 1]
    }

    /// The stage a stored session prescribes, read back from its structure.
    ///
    /// Read back rather than stored, because nothing on `ScheduledWorkout` or `TrainingWeek`
    /// says which stage it is and adding a field would be a CloudKit schema deployment. A
    /// session the runner or the app has since rewritten matches no stage and returns nil.
    static func stage(matching structure: WorkoutStructure?) -> Stage? {
        guard let structure, structure.mainSets.count == 1, let set = structure.mainSets.first else {
            return nil
        }
        let run = Int((set.workSegment.durationSeconds ?? 0).rounded())
        let walk = Int((set.recoverySegment.durationSeconds ?? 0).rounded())
        return stages.first {
            $0.repetitions == set.repetitions && $0.runSeconds == run && $0.walkSeconds == walk
        }
    }

    // MARK: Starting point

    /// How far into the program a runner starts, from the one question that places them:
    /// how long they can run without stopping today.
    enum StartingPoint: String, CaseIterable, Identifiable, Sendable {
        /// Not yet, or less than a minute.
        case notYet
        /// Two or three minutes.
        case fewMinutes
        /// About five minutes.
        case fiveMinutes
        /// Ten minutes or more, but not yet the twenty or so that a 5K plan starts from.
        case tenMinutes

        var id: String { rawValue }

        /// The first stage whose longest run is no longer than what the runner said they can
        /// already do, so week one is never a step up from today.
        var firstStage: Int {
            switch self {
            case .notYet:      return 1
            case .fewMinutes:  return 3
            case .fiveMinutes: return 5
            case .tenMinutes:  return 6
            }
        }

        var localizedName: String {
            switch self {
            case .notYet:
                return String(localized: "Not yet, or under a minute", comment: "Start Running starting point answer")
            case .fewMinutes:
                return String(localized: "2 to 3 minutes", comment: "Start Running starting point answer")
            case .fiveMinutes:
                return String(localized: "About 5 minutes", comment: "Start Running starting point answer")
            case .tenMinutes:
                return String(localized: "10 minutes or more", comment: "Start Running starting point answer")
            }
        }

        /// How many weeks the plan runs from this starting point.
        var weeks: Int { StartRunningProgram.stageCount - firstStage + 1 }
    }

    // MARK: Formatting

    /// "2 min" for whole minutes, "1:30" otherwise, the way a runner says an interval.
    static func clock(_ seconds: Int) -> String {
        if seconds % 60 == 0 {
            return String(localized: "\(seconds / 60) min", comment: "A whole number of minutes, e.g. '2 min'")
        }
        return Double(seconds).durationString
    }
}
