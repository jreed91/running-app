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
    @Guide(description: "Short metric label, at most 10 characters")
    let label: String
    @Guide(description: "Compact metric value, at most 12 characters")
    let value: String
    @Guide(description: "Optional change indicator, at most 8 characters")
    let delta: String?
    let tone: CoachTone
}

@available(iOS 26.0, *)
@Generable
struct GeneratedActionItem: Sendable {
    @Guide(description: "Specific action, at most 6 words")
    let title: String
    @Guide(description: "One sentence explaining what to do and why")
    let detail: String
    let priority: ActionPriority
    @Guide(description: "Compact metric badge, at most 10 characters")
    let metric: String
    let tone: CoachTone
}

@available(iOS 26.0, *)
@Generable
struct GeneratedNextWorkout: Sendable {
    @Guide(description: "Specific next workout recommendation")
    let title: String
    @Guide(description: "One sentence explaining why this should come next")
    let rationale: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedCoachInsight: Sendable {
    @Guide(description: "Short coaching headline, at most 8 words")
    let headline: String
    @Guide(description: "One plain-language sentence with the main takeaway")
    let summary: String
    @Guide(description: "A 2-3 sentence coaching explanation: the read, the key evidence, and the practical adjustment")
    let fullAnalysis: String
    @Guide(description: "Confidence score", .range(0...100))
    let confidence: Int
    @Guide(description: "Exactly four compact evidence chips", .count(4))
    let evidence: [GeneratedEvidence]
    @Guide(description: "Exactly three prioritised, actionable items", .count(3))
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
    @Guide(description: "One concise paragraph explaining why this adaptation is appropriate")
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
    @Guide(description: "One short sentence explaining the change, under 120 characters")
    let explanation: String
    let intervals: [GeneratedAdaptationInterval]
}

@available(iOS 26.0, *)
@Generable
struct GeneratedPlanAdaptation: Sendable {
    @Guide(description: "Exactly one adaptation per workout id in the provided context")
    let adaptations: [GeneratedPlanAdaptationItem]
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
#endif
