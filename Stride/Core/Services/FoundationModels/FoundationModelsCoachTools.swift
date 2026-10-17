#if canImport(FoundationModels)
import Foundation
import FoundationModels

// MARK: - Coach tools
//
// Read-only Foundation Models tools over a `CoachLookup`, so the coach can search the
// runner's log while it writes instead of answering from one fixed summary. Each tool is
// a thin wrapper: the query and its formatting live in `CoachLookup`, where they are
// tested without the framework. The tools are `Sendable` value types holding a plain copy
// of the data, as Apple's `Tool` protocol requires, and none of them can write anything.
//
// Names and descriptions follow Apple's guidance for tools: a short verb-led name in
// plain English, and a one-sentence description of what the tool gives back, with no
// implementation detail. Both go into the prompt verbatim, so every word costs tokens.

/// The kinds of run a tool can filter by. A closed set so the model cannot ask for a
/// type the app does not have.
@available(iOS 26.0, *)
@Generable
enum CoachRunKind: String, Sendable {
    case any
    case easy
    case tempo
    case interval
    case longRun
    case race
}

@available(iOS 26.0, *)
extension CoachRunKind {
    var workoutType: WorkoutType? {
        switch self {
        case .any:      return nil
        case .easy:     return .easy
        case .tempo:    return .tempo
        case .interval: return .interval
        case .longRun:  return .longRun
        case .race:     return .race
        }
    }
}

@available(iOS 26.0, *)
struct FindRunsTool: Tool {
    let lookup: CoachLookup
    let budget: CoachToolBudget

    let name = "findRuns"
    let description = "Finds the runner's past runs, newest first, with date, type, distance, time, pace, heart rate and how it felt."

    @Generable
    struct Arguments {
        @Guide(description: "Which kind of run to find; any for every kind")
        let kind: CoachRunKind
        @Guide(description: "How many days back to look", .range(1...180))
        let withinDays: Int
        @Guide(description: "The most runs to return", .range(1...10))
        let limit: Int
    }

    func call(arguments: Arguments) async throws -> String {
        budget.spend {
            lookup.findRuns(type: arguments.kind.workoutType, withinDays: arguments.withinDays, limit: arguments.limit)
        }
    }
}

@available(iOS 26.0, *)
struct WeeklyTotalsTool: Tool {
    let lookup: CoachLookup
    let budget: CoachToolBudget

    let name = "getWeeklyTotals"
    let description = "Gives the runner's total distance and number of runs for each recent week, newest first."

    @Generable
    struct Arguments {
        @Guide(description: "How many weeks to cover, including this one", .range(1...12))
        let weeks: Int
    }

    func call(arguments: Arguments) async throws -> String {
        budget.spend {
            lookup.weeklyTotals(weeks: arguments.weeks)
        }
    }
}

@available(iOS 26.0, *)
struct PlanSessionsTool: Tool {
    let lookup: CoachLookup
    let budget: CoachToolBudget

    let name = "getPlanSessions"
    let description = "Lists the runner's planned runs around today, with type, distance and whether each was done, missed or is still to come."

    @Generable
    struct Arguments {
        @Guide(description: "How many days before today to include", .range(0...28))
        let daysBack: Int
        @Guide(description: "How many days after today to include", .range(0...28))
        let daysAhead: Int
    }

    func call(arguments: Arguments) async throws -> String {
        budget.spend {
            lookup.planSessions(daysBack: arguments.daysBack, daysAhead: arguments.daysAhead)
        }
    }
}

/// What `rankRuns` can order by.
@available(iOS 26.0, *)
@Generable
enum CoachRunRanking: String, Sendable {
    case fastest
    case longest
    case highestHeartRate
}

@available(iOS 26.0, *)
extension CoachRunRanking {
    var ranking: CoachLookup.Ranking {
        switch self {
        case .fastest:          return .fastest
        case .longest:          return .longest
        case .highestHeartRate: return .highestHeartRate
        }
    }
}

/// The race distances `predictRaceTimes` answers for.
@available(iOS 26.0, *)
@Generable
enum CoachRaceDistance: String, Sendable {
    case all
    case fiveK
    case tenK
    case halfMarathon
    case marathon
}

@available(iOS 26.0, *)
extension CoachRaceDistance {
    var meters: Double? {
        switch self {
        case .all:          return nil
        case .fiveK:        return 5_000
        case .tenK:         return 10_000
        case .halfMarathon: return 21_097.5
        case .marathon:     return 42_195
        }
    }
}

@available(iOS 26.0, *)
struct RankRunsTool: Tool {
    let lookup: CoachLookup
    let budget: CoachToolBudget

    let name = "rankRuns"
    let description = "Finds the runner's fastest, longest or highest heart rate runs in a recent window, best first."

    @Generable
    struct Arguments {
        @Guide(description: "Which kind of run to rank; any for every kind")
        let kind: CoachRunKind
        @Guide(description: "What to rank by")
        let by: CoachRunRanking
        @Guide(description: "How many days back to look", .range(1...180))
        let withinDays: Int
        @Guide(description: "The most runs to return", .range(1...10))
        let limit: Int
    }

    func call(arguments: Arguments) async throws -> String {
        budget.spend {
            lookup.rankRuns(
                type: arguments.kind.workoutType,
                withinDays: arguments.withinDays,
                by: arguments.by.ranking,
                limit: arguments.limit
            )
        }
    }
}

@available(iOS 26.0, *)
struct CompareRunsTool: Tool {
    let lookup: CoachLookup
    let budget: CoachToolBudget

    let name = "compareRuns"
    let description = "Compares the runner's recent days with the same number of days before them: runs, distance, average pace, heart rate and how many felt hard."

    @Generable
    struct Arguments {
        @Guide(description: "Which kind of run to compare; any for every kind")
        let kind: CoachRunKind
        @Guide(description: "How many days each window covers", .range(7...90))
        let days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        budget.spend {
            lookup.compareRuns(type: arguments.kind.workoutType, days: arguments.days)
        }
    }
}

@available(iOS 26.0, *)
struct RacePredictionsTool: Tool {
    let lookup: CoachLookup
    let budget: CoachToolBudget

    let name = "predictRaceTimes"
    let description = "Gives the race times and paces the runner's current fitness predicts for 5K, 10K, half marathon and marathon."

    @Generable
    struct Arguments {
        @Guide(description: "Which race distance to predict; all for every one")
        let distance: CoachRaceDistance
    }

    func call(arguments: Arguments) async throws -> String {
        budget.spend {
            lookup.racePredictions(for: arguments.distance.meters)
        }
    }
}

@available(iOS 26.0, *)
extension CoachLookup {
    /// The tools a session gets for this lookup: all six for the chat, the two that reach
    /// back past the prompt for the run read (see ``CoachLookup/ToolSet``). Built once per
    /// request, so the tools of one answer share one ``CoachToolBudget``.
    var tools: [any Tool] {
        let budget = CoachToolBudget(calls: toolSet.maximumCalls)
        switch toolSet {
        case .runRead:
            return [FindRunsTool(lookup: self, budget: budget), CompareRunsTool(lookup: self, budget: budget)]
        case .chat:
            return [
                FindRunsTool(lookup: self, budget: budget),
                RankRunsTool(lookup: self, budget: budget),
                WeeklyTotalsTool(lookup: self, budget: budget),
                CompareRunsTool(lookup: self, budget: budget),
                PlanSessionsTool(lookup: self, budget: budget),
                RacePredictionsTool(lookup: self, budget: budget),
            ]
        }
    }
}
#endif
