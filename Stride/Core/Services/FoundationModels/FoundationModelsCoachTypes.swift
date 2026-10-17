#if canImport(FoundationModels)
import Foundation
import FoundationModels

// MARK: - Guided-generation output types
//
// These `@Generable` types replace the hand-written JSON schema (and the ~700 lines
// of fault-tolerant JSON parsing in `AICoachService`) for the on-device path. Guided
// generation uses constrained decoding, so the framework *guarantees* the model emits
// exactly this structure — the `@Guide` annotations carry the coaching rules directly.
//
// Each type maps to the `Codable` value types in `AICoachService`, so the downstream
// mapping/validation (`isValidAdaptation`, `makeScheduledWorkout`, …) is reused unchanged.

@available(iOS 26.0, *)
@Generable
enum CoachTone: String, Sendable {
    case warning
    case success
    case brand
    case easy
    case interval
    case neutral
}

@available(iOS 26.0, *)
@Generable
enum ActionPriority: String, Sendable {
    case high
    case medium
    case low

    var displayValue: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

@available(iOS 26.0, *)
@Generable
enum AdaptedWorkoutKind: String, Sendable {
    case easy
    case tempo
    case interval
    case longRun

    /// Matches the strings `AICoachService.workoutType(from:)` already understands.
    var displayValue: String {
        switch self {
        case .easy: return "Easy"
        case .tempo: return "Tempo"
        case .interval: return "Interval"
        case .longRun: return "Long Run"
        }
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedEvidence: Sendable {
    @Guide(description: "What this number is, in plain words, at most 10 characters (for example \"Avg pace\")")
    let label: String
    @Guide(description: "The value with its unit, as a watch shows it, at most 12 characters (for example \"5:20/km\")")
    let value: String
    @Guide(description: "Optional change against the plan or the runner's usual, at most 8 characters (for example \"-12s\" or \"+4 bpm\")")
    let delta: String?
    let tone: CoachTone
}

@available(iOS 26.0, *)
@Generable
struct GeneratedActionItem: Sendable {
    @Guide(description: "What to do, said as an instruction to the runner, at most 6 words")
    let title: String
    @Guide(description: "One plain sentence, addressed to \"you\", saying what to do and why")
    let detail: String
    let priority: ActionPriority
    @Guide(description: "The number this action turns on, with its unit, at most 10 characters")
    let metric: String
    let tone: CoachTone
}

@available(iOS 26.0, *)
@Generable
struct GeneratedNextWorkout: Sendable {
    @Guide(description: "The next run to do, named the way a coach would say it (for example \"Easy 5 km at 6:10 per km\"). If a next run is planned, this is that run, changed only if this run gives a reason")
    let title: String
    @Guide(description: "One plain sentence, addressed to \"you\", saying why this comes next")
    let rationale: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedCoachInsight: Sendable {
    @Guide(description: "The verdict: did this run do its job, in plain words, at most 8 words (for example \"Tempo on target, last 2 km faded\")")
    let headline: String
    @Guide(description: "Why, in one plain sentence addressed to \"you\", naming the one number that shows it, with no jargon")
    let summary: String
    @Guide(description: "2-3 short, plain sentences addressed to \"you\": what happened, the number that shows it, and what to do about it. Write paces as minutes and seconds, and explain any training term you use")
    let fullAnalysis: String
    @Guide(description: "Confidence score", .range(0...100))
    let confidence: Int
    @Guide(description: "Exactly three numbers that prove the verdict, each compared with the plan or the runner's usual where the data allows", .count(3))
    let evidence: [GeneratedEvidence]
    @Guide(description: "Exactly three things to do next, most important first, each different from the others", .count(3))
    let actionItems: [GeneratedActionItem]
    let nextWorkout: GeneratedNextWorkout
}

@available(iOS 26.0, *)
@Generable
struct GeneratedAdaptationInterval: Sendable {
    @Guide(description: "Number of repetitions", .range(1...30))
    let repetitions: Int
    let distanceMeters: Double?
    let durationSeconds: Double?
    @Guide(description: "Target pace in seconds per kilometre", .range(120...900))
    let targetPaceSecondsPerKm: Double?
    @Guide(description: "Recovery duration in seconds")
    let recoverySeconds: Double
    @Guide(description: "Either 'jog' or 'walk'")
    let recoveryType: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedWorkoutAdaptation: Sendable {
    let workoutType: AdaptedWorkoutKind
    @Guide(description: "Target distance in metres", .range(500...50000))
    let targetDistanceMeters: Double?
    @Guide(description: "Lower bound of the target pace in seconds per kilometre", .range(120...900))
    let targetPaceLowerBound: Double?
    @Guide(description: "Upper bound of the target pace in seconds per kilometre", .range(120...900))
    let targetPaceUpperBound: Double?
    @Guide(description: "One or two plain sentences, addressed to \"you\", saying what changed and why. Write paces as minutes and seconds (for example \"5:20 per km\"), never as a count of seconds")
    let explanation: String
    @Guide(description: "Interval prescription; empty unless the workout type is interval")
    let intervals: [GeneratedAdaptationInterval]
}

@available(iOS 26.0, *)
@Generable
struct GeneratedPlanAdaptationItem: Sendable {
    @Guide(description: "The workout id copied exactly from the provided context")
    let workoutID: String
    let workoutType: AdaptedWorkoutKind
    @Guide(description: "Target distance in metres", .range(500...50000))
    let targetDistanceMeters: Double?
    @Guide(description: "Lower bound of the target pace in seconds per kilometre", .range(120...900))
    let targetPaceLowerBound: Double?
    @Guide(description: "Upper bound of the target pace in seconds per kilometre", .range(120...900))
    let targetPaceUpperBound: Double?
    @Guide(description: "One plain sentence under 120 characters, addressed to \"you\", saying what changed and why. Write paces as minutes and seconds, never as a count of seconds")
    let explanation: String
    let intervals: [GeneratedAdaptationInterval]
}

@available(iOS 26.0, *)
@Generable
struct GeneratedPlanAdaptation: Sendable {
    @Guide(description: "Exactly one adaptation per workout id in the provided context")
    let adaptations: [GeneratedPlanAdaptationItem]
}

@available(iOS 26.0, *)
@Generable
struct GeneratedCoachTip: Sendable {
    @Guide(description: "The tip's id, copied exactly from the list")
    let id: String
    @Guide(description: "A short heading said to the runner, at most 6 words")
    let title: String
    @Guide(description: "Two or three short, plain sentences addressed to \"you\". Keep every number, amount and unit exactly as written in the tip, and add no other numbers")
    let message: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedCoachTips: Sendable {
    @Guide(description: "Exactly one rewritten tip per id in the list, in the same order")
    let tips: [GeneratedCoachTip]
}

// MARK: - Mapping to the existing structured value types

@available(iOS 26.0, *)
extension GeneratedCoachInsight {
    func toStructuredResponse() -> AICoachStructuredResponse {
        AICoachStructuredResponse(
            headline: headline,
            summary: summary,
            fullAnalysis: fullAnalysis,
            confidence: confidence,
            evidence: evidence.map(\.domainValue),
            actionItems: actionItems.map(\.domainValue),
            nextWorkout: AICoachStructuredResponse.NextWorkout(
                title: nextWorkout.title,
                rationale: nextWorkout.rationale
            )
        )
    }
}

@available(iOS 26.0, *)
extension GeneratedEvidence {
    var domainValue: AICoachEvidenceItem {
        AICoachEvidenceItem(label: label, value: value, delta: delta, tone: tone.rawValue)
    }
}

@available(iOS 26.0, *)
extension GeneratedActionItem {
    var domainValue: AICoachActionItem {
        AICoachActionItem(
            title: title,
            detail: detail,
            priority: priority.displayValue,
            metric: metric,
            tone: tone.rawValue
        )
    }
}

@available(iOS 26.0, *)
extension GeneratedAdaptationInterval {
    var domainValue: AIWorkoutAdaptationInterval {
        AIWorkoutAdaptationInterval(
            repetitions: repetitions,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            targetPaceSecondsPerKm: targetPaceSecondsPerKm,
            recoverySeconds: recoverySeconds,
            recoveryType: recoveryType
        )
    }
}

@available(iOS 26.0, *)
extension GeneratedWorkoutAdaptation {
    /// `workout_structure` is intentionally left `nil`; `AICoachService` derives it
    /// locally (see `fallbackStructure`) exactly as it does for the cloud plan path.
    func toAdaptationResponse() -> AIWorkoutAdaptationResponse {
        AIWorkoutAdaptationResponse(
            workoutType: workoutType.displayValue,
            targetDistanceMeters: targetDistanceMeters,
            targetPaceLowerBound: targetPaceLowerBound,
            targetPaceUpperBound: targetPaceUpperBound,
            explanation: explanation,
            intervals: intervals.map(\.domainValue),
            workoutStructure: nil
        )
    }
}

@available(iOS 26.0, *)
extension GeneratedPlanAdaptation {
    func toPlanAdaptationResponse() -> AIWorkoutPlanAdaptationResponse {
        AIWorkoutPlanAdaptationResponse(
            adaptations: adaptations.map { item in
                AIWorkoutPlanAdaptation(
                    workoutID: item.workoutID,
                    workoutType: item.workoutType.displayValue,
                    targetDistanceMeters: item.targetDistanceMeters,
                    targetPaceLowerBound: item.targetPaceLowerBound,
                    targetPaceUpperBound: item.targetPaceUpperBound,
                    explanation: item.explanation,
                    intervals: item.intervals.map(\.domainValue),
                    workoutStructure: nil
                )
            }
        )
    }
}

@available(iOS 26.0, *)
extension GeneratedCoachTips {
    func toDrafts() -> [CoachTipDraft] {
        tips.map { CoachTipDraft(id: $0.id, title: $0.title, message: $0.message) }
    }
}
#endif
