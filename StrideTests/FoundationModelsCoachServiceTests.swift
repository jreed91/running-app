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

/// Captures the prompt the service builds so tests can assert on what the coach is told.
private actor PromptRecorder {
    private(set) var prompt = ""

    func record(_ prompt: String) {
        self.prompt = prompt
    }
}

private struct RecordingOnDeviceCoach: OnDeviceCoachGenerating {
    let recorder: PromptRecorder
    let insight: AICoachStructuredResponse

    func isAvailable() async -> Bool { true }
    func unavailableReason() async -> String? { nil }

    func generateCoachInsight(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> AICoachStructuredResponse {
        await recorder.record(prompt)
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
        ""
    }
}

/// Reports a canned Private Cloud Compute status, and can fail chat the way an exhausted
/// daily quota does, so the service's pass-through and error plumbing can be asserted
/// without a real PCC session.
private struct QuotaReportingCoach: OnDeviceCoachGenerating {
    var status: ServerModelStatus?
    var chatError: OnDeviceCoachError?

    func isAvailable() async -> Bool { true }
    func unavailableReason() async -> String? { nil }
    func serverModelStatus() async -> ServerModelStatus? { status }

    func generateCoachInsight(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> AICoachStructuredResponse {
        throw OnDeviceCoachError.unavailable
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
        if let chatError { throw chatError }
        return "Keep your easy runs easy."
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

    @Test("The insight prompt carries the run's splits and heart-rate zone breakdown")
    func promptIncludesSplitsAndZones() async {
        let recorder = PromptRecorder()
        let backend = RecordingOnDeviceCoach(recorder: recorder, insight: sampleStructured())
        let service = AICoachService(onDeviceBackend: backend)

        let workout = RunWorkout(date: Date(), distanceMeters: 4_000, durationSeconds: 1_240, workoutType: .easy)
        workout.splits = [
            Split(kilometer: 1, paceSecondsPerKm: 300, heartRate: 138, elevationGainMeters: 5, cumulativeDistanceMeters: 1_000),
            Split(kilometer: 2, paceSecondsPerKm: 305, heartRate: 145, elevationGainMeters: 3, cumulativeDistanceMeters: 2_000),
            Split(kilometer: 3, paceSecondsPerKm: 315, heartRate: 152, elevationGainMeters: 0, cumulativeDistanceMeters: 3_000),
            Split(kilometer: 4, paceSecondsPerKm: 320, heartRate: 158, elevationGainMeters: -4, cumulativeDistanceMeters: 4_000)
        ]
        let profile = UserProfile(
            name: "Runner",
            goalRace: .fiveK,
            goalFinishTime: 1_500,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )
        profile.maxHeartRateBPM = 190
        let zones = HeartRateZoneService.timeInZones(
            bpmSamples: [120, 130, 140, 150, 160, 175],
            totalSeconds: workout.durationSeconds,
            maxHR: 190
        )

        _ = await service.evaluateWithProvider(
            workout: workout,
            recentHistory: [],
            profile: profile,
            provider: .appleOnDevice,
            heartRateZones: zones
        )

        let prompt = await recorder.prompt
        #expect(prompt.contains("km 1: pace 5:00 min/km, hr 138"))
        #expect(prompt.contains("km 4: pace 5:20 min/km, hr 158"))
        #expect(prompt.contains("Split trend:"))
        #expect(prompt.contains("fastest km 1"))
        #expect(prompt.contains("positive split"))
        #expect(prompt.contains("Time in heart-rate zones:"))
        #expect(prompt.contains("Zones derived from max HR 190 bpm."))
        #expect(prompt.contains("Z5 Max (171-190 bpm)"))
        #expect(prompt.contains("Heart rate sat mostly in"))
    }

    @Test("Without zone data the prompt says so rather than dropping the section")
    func promptWithoutZoneData() async {
        let recorder = PromptRecorder()
        let backend = RecordingOnDeviceCoach(recorder: recorder, insight: sampleStructured())
        let service = AICoachService(onDeviceBackend: backend)
        let workout = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 2_500, workoutType: .easy)

        _ = await service.evaluateWithProvider(
            workout: workout,
            recentHistory: [],
            profile: nil,
            provider: .appleOnDevice
        )

        let prompt = await recorder.prompt
        #expect(prompt.contains("No heart-rate zone data."))
        #expect(prompt.contains("No split data."))
        #expect(prompt.contains("Not enough splits to derive a trend."))
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

    // MARK: - Private Cloud Compute status & quota

    @Test("A backend with no server model reports no Private Cloud Compute status")
    func noServerModelStatusByDefault() async {
        let backend = FakeOnDeviceCoach(available: true, insight: sampleStructured())
        let service = AICoachService(onDeviceBackend: backend)

        #expect(await service.serverModelStatus() == nil)
        #expect(await AICoachService(onDeviceBackend: nil).serverModelStatus() == nil)
    }

    @Test("Server model status is passed through from the backend")
    func serverModelStatusIsPassedThrough() async {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let backend = QuotaReportingCoach(
            status: ServerModelStatus(
                availability: .available,
                quota: .belowLimit(approachingLimit: true),
                resetDate: reset,
                canRequestLimitIncrease: true
            )
        )
        let service = AICoachService(onDeviceBackend: backend)

        let status = await service.serverModelStatus()
        #expect(status?.isAvailable == true)
        #expect(status?.isApproachingLimit == true)
        #expect(status?.isLimitReached == false)
        #expect(status?.resetDate == reset)
        #expect(status?.canRequestLimitIncrease == true)
    }

    @Test("Quota messages only appear when there is something to say")
    func quotaMessageIsQuietBelowTheLimit() {
        func status(_ quota: ServerModelStatus.Quota) -> ServerModelStatus {
            ServerModelStatus(
                availability: .available,
                quota: quota,
                resetDate: nil,
                canRequestLimitIncrease: false
            )
        }

        // Comfortably below the limit is not news — no status line at all.
        #expect(status(.belowLimit(approachingLimit: false)).quotaMessage == nil)
        #expect(status(.belowLimit(approachingLimit: true)).quotaMessage != nil)
        #expect(status(.limitReached).quotaMessage != nil)
        #expect(status(.limitReached).isLimitReached)
    }

    @Test("An exhausted daily quota surfaces as an error rather than a silent downgrade")
    func quotaExhaustionPropagatesFromChat() async {
        let resetDate = Date(timeIntervalSince1970: 1_800_000_000)
        let backend = QuotaReportingCoach(status: nil, chatError: .serverQuotaExceeded(resetDate: resetDate))
        let service = AICoachService(onDeviceBackend: backend)

        await #expect(throws: OnDeviceCoachError.self) {
            _ = try await service.chatWithProvider(
                provider: .applePrivateCloud,
                context: "",
                messages: []
            )
        }
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
