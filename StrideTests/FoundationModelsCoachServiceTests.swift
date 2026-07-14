import Testing
import Foundation
@testable import Stride

// MARK: - Fake on-device backend

private struct FakeOnDeviceCoach: OnDeviceCoachGenerating {
    var available: Bool
    var insight: AICoachStructuredResponse

    func isAvailable() async -> Bool { available }
    func unavailableReason() async -> String? { available ? nil : "unavailable" }

    func generateCoachInsight(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> AICoachStructuredResponse {
        onPartial(insight.summary)
        return insight
    }

    func generateWorkoutAdaptation(
        instructions: String,
        prompt: String,
        useServerModel: Bool
    ) async throws -> AIWorkoutAdaptationResponse {
        throw OnDeviceCoachError.unavailable
    }

    func generatePlanAdaptation(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> AIWorkoutPlanAdaptationResponse {
        AIWorkoutPlanAdaptationResponse(adaptations: [])
    }

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        useServerModel: Bool
    ) async throws -> String {
        "Keep your easy runs easy."
    }
}

private func sampleStructured() -> AICoachStructuredResponse {
    AICoachStructuredResponse(
        headline: "Strong Negative Split",
        summary: "You finished faster than you started — great control.",
        fullAnalysis: "Your closing splits were quicker than the opening ones, a sign of disciplined pacing.",
        confidence: 88,
        evidence: [
            AICoachEvidenceItem(label: "Pace", value: "5:10/km", delta: "-0:12", tone: "success")
        ],
        actionItems: [
            AICoachActionItem(title: "Repeat the pattern", detail: "Hold this pacing on the next easy run.", priority: "Medium", metric: "neg split", tone: "easy")
        ],
        nextWorkout: AICoachStructuredResponse.NextWorkout(
            title: "40 minute easy run",
            rationale: "Consolidate the aerobic gains from a well-paced session."
        )
    )
}

@MainActor
struct FoundationModelsCoachServiceTests {

    @Test("AIProvider exposes only keyless Apple models")
    func providerFlags() {
        #expect(AIProvider.allCases == [.appleOnDevice, .applePrivateCloud])
        #expect(AIProvider.appleOnDevice.usesPrivateCloudCompute == false)
        #expect(AIProvider.applePrivateCloud.usesPrivateCloudCompute)
    }

    @Test("On-device insight is used when the model is available, with no API key")
    func usesOnDeviceWhenAvailable() async {
        let backend = FakeOnDeviceCoach(available: true, insight: sampleStructured())
        let service = AICoachService(onDeviceBackend: backend)
        let workout = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 2_500, workoutType: .easy)

        let insight = await service.evaluateWithProvider(
            workout: workout,
            recentHistory: [],
            profile: nil,
            provider: .appleOnDevice
        )

        #expect(insight.apiReady)
        #expect(insight.headline == "Strong Negative Split")
        #expect(insight.nextWorkoutSuggestion == "40 minute easy run")
    }

    @Test("Falls back to a local heuristic insight when the on-device model is unavailable")
    func fallsBackWhenUnavailable() async {
        let backend = FakeOnDeviceCoach(available: false, insight: sampleStructured())
        let service = AICoachService(onDeviceBackend: backend)
        let workout = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 2_500, workoutType: .easy)

        let insight = await service.evaluateWithProvider(
            workout: workout,
            recentHistory: [],
            profile: nil,
            provider: .appleOnDevice
        )

        // Local fallback is not an AI/model result, so it is not marked apiReady.
        #expect(insight.apiReady == false)
        #expect(insight.headline == "On-Device Summary")
    }

    @Test("With no backend at all, evaluation degrades to the local heuristic insight")
    func localHeuristicWithoutBackend() async {
        let service = AICoachService(onDeviceBackend: nil)
        let workout = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 2_500, workoutType: .easy)

        let insight = await service.evaluateWithProvider(
            workout: workout,
            recentHistory: [],
            profile: nil,
            provider: .applePrivateCloud
        )

        #expect(insight.apiReady == false)
        #expect(insight.headline == "On-Device Summary")
    }
}

#if canImport(FoundationModels)
import FoundationModels

// No @available attribute here: the deployment target is iOS 27.0 (>= the iOS 26.0
// availability on the @Generable types), and swift-testing rejects @Test functions
// inside an availability-constrained type ("Attribute 'Test' cannot be applied...").
struct GeneratedTypeMappingTests {

    @Test("Generated insight maps into the structured response shape")
    func mapsGeneratedInsight() {
        let generated = GeneratedCoachInsight(
            headline: "Controlled Effort",
            summary: "Even pacing throughout.",
            fullAnalysis: "Splits stayed within a tight band, showing good control.",
            confidence: 80,
            evidence: [GeneratedEvidence(label: "Pace", value: "5:00/km", delta: nil, tone: .success)],
            actionItems: [GeneratedActionItem(title: "Hold form", detail: "Keep cadence steady.", priority: .medium, metric: "180 spm", tone: .neutral)],
            nextWorkout: GeneratedNextWorkout(title: "Easy 30", rationale: "Recover well.")
        )

        let structured = generated.toStructuredResponse()
        #expect(structured.headline == "Controlled Effort")
        #expect(structured.confidence == 80)
        #expect(structured.evidence.first?.tone == "success")
        #expect(structured.actionItems.first?.priority == "Medium")
    }

    @Test("Generated workout adaptation maps to the domain workout type strings")
    func mapsGeneratedAdaptation() {
        let generated = GeneratedWorkoutAdaptation(
            workoutType: .longRun,
            targetDistanceMeters: 18_000,
            targetPaceLowerBound: 360,
            targetPaceUpperBound: 390,
            explanation: "Extended the long run to build endurance for the goal race.",
            intervals: []
        )

        let response = generated.toAdaptationResponse()
        #expect(response.workoutType == "Long Run")
        #expect(response.workoutStructure == nil)
    }
}
#endif
