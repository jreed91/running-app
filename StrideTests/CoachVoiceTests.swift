import Testing
import Foundation
@testable import Stride

/// The coach words its replies for the runner's experience (`CoachVoice`): plain for a
/// new runner, technical for an experienced one. These pin which paragraph each level
/// gets and that the service hands it to the model on every coach surface.
@MainActor
struct CoachVoiceTests {

    @Test("Each fitness level picks its own voice, and no profile reads as recreational")
    func levelsMapToVoices() {
        #expect(CoachVoice(.beginner) == .newRunner)
        #expect(CoachVoice(.intermediate) == .recreational)
        #expect(CoachVoice(.advanced) == .experienced)
        #expect(CoachVoice(.competitive) == .competitive)
        #expect(CoachVoice(nil) == .recreational)
    }

    @Test("A new runner is promised no jargon; an experienced runner gets terms undefined")
    func guidanceDiffersByLevel() {
        let newRunner = CoachVoice.newRunner.guidance
        #expect(newRunner.contains("no training jargon"))
        #expect(newRunner.contains("walk break is normal"))
        #expect(!newRunner.contains("without defining"))

        let recreational = CoachVoice.recreational.guidance
        #expect(recreational.contains("explain it in a few words"))

        for voice in [CoachVoice.experienced, .competitive] {
            #expect(voice.guidance.contains("without defining them"))
            #expect(!voice.guidance.contains("explain it in a few words"))
        }
        #expect(CoachVoice.competitive.guidance.contains("goal race"))
    }

    @Test("Every instruction set ends with the level's paragraph")
    func instructionsCarryTheVoice() {
        for level in FitnessLevel.allCases {
            let guidance = CoachVoice(level).guidance
            #expect(AICoachService.chatInstructions(for: level).hasSuffix(guidance))
            #expect(AICoachService.insightInstructions(for: level).hasSuffix(guidance))
            #expect(AICoachService.adaptationInstructions(for: level).hasSuffix(guidance))
            #expect(AICoachService.planAdaptationInstructions(for: level).hasSuffix(guidance))
        }
    }

    @Test("The shared instructions no longer tell every runner to have terms explained")
    func sharedTextLeavesTermsToTheVoice() {
        // Only the recreational paragraph asks for a term to be explained; if the shared
        // text still did, an experienced runner would get both instructions at once.
        let expert = AICoachService.insightInstructions(for: .advanced)
        #expect(!expert.contains("Explain a training term"))
        #expect(!expert.contains("explain it in a few words"))
        #expect(!AICoachService.chatInstructions(for: .advanced).contains("explain it in a few words"))
    }

    @Test("The chat sends the runner's level to the model")
    func chatUsesTheLevel() async throws {
        let recorder = InstructionRecorder()
        let service = AICoachService(onDeviceBackend: InstructionRecordingCoach(recorder: recorder))

        _ = try await service.chatWithProvider(
            provider: .appleOnDevice, context: "ctx", messages: [], fitnessLevel: .beginner
        )
        _ = try await service.chatWithProvider(provider: .appleOnDevice, context: "ctx", messages: [])

        let sent = await recorder.instructions
        #expect(sent == [
            AICoachService.chatInstructions(for: .beginner),
            AICoachService.chatInstructions(for: nil)
        ])
    }

    @Test("The run read sends the profile's level to the model")
    func runReadUsesTheProfileLevel() async {
        let recorder = InstructionRecorder()
        let service = AICoachService(onDeviceBackend: InstructionRecordingCoach(recorder: recorder))
        let workout = RunWorkout(date: Date(), distanceMeters: 5_000, durationSeconds: 1_800, workoutType: .easy)
        let profile = UserProfile(
            name: "Runner",
            goalRace: .halfMarathon,
            goalFinishTime: 6_000,
            weeklyRunDays: 5,
            fitnessLevel: .competitive
        )

        _ = await service.evaluateWithProvider(
            workout: workout,
            recentHistory: [],
            profile: profile,
            provider: .appleOnDevice
        )

        let sent = await recorder.instructions
        #expect(sent == [AICoachService.insightInstructions(for: .competitive)])
    }
}

// MARK: - Fake backend

private actor InstructionRecorder {
    private(set) var instructions: [String] = []

    func record(_ text: String) {
        instructions.append(text)
    }
}

/// Records the instructions each chat and run-read request was sent with.
private struct InstructionRecordingCoach: OnDeviceCoachGenerating {
    let recorder: InstructionRecorder

    func isAvailable() async -> Bool { true }
    func unavailableReason() async -> String? { nil }

    func generateCoachInsight(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AICoachStructuredResponse {
        await recorder.record(instructions)
        return AICoachStructuredResponse(
            headline: "Easy run done easy",
            summary: "You kept it relaxed.",
            fullAnalysis: "You kept it relaxed the whole way.",
            confidence: 80,
            evidence: [],
            actionItems: [],
            nextWorkout: AICoachStructuredResponse.NextWorkout(title: "30 minute easy run", rationale: "Keep building.")
        )
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
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AIWorkoutPlanAdaptationResponse {
        throw OnDeviceCoachError.unavailable
    }

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        await recorder.record(instructions)
        return "ok"
    }
}
