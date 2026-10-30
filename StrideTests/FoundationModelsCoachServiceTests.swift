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
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AICoachStructuredResponse {
        await onPartialText(insight.summary)
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
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AIWorkoutPlanAdaptationResponse {
        AIWorkoutPlanAdaptationResponse(adaptations: [])
    }

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
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
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
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
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AIWorkoutPlanAdaptationResponse {
        AIWorkoutPlanAdaptationResponse(adaptations: [])
    }

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
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
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
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
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AIWorkoutPlanAdaptationResponse {
        AIWorkoutPlanAdaptationResponse(adaptations: [])
    }

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        if let chatError { throw chatError }
        // Cumulative snapshots, the way `streamResponse` delivers them — and awaited,
        // so the caller has applied each before the next arrives.
        await onPartialText("Keep your")
        await onPartialText("Keep your easy runs")
        await onPartialText("Keep your easy runs easy.")
        return "Keep your easy runs easy."
    }
}

/// Records which model each insight request asked for.
private actor ServerModelCalls {
    private(set) var flags: [Bool] = []

    func record(_ useServerModel: Bool) {
        flags.append(useServerModel)
    }
}

/// Fails every Private Cloud Compute request the way an exhausted daily quota does, and
/// answers on-device; returns `adaptation` for a single-session adaptation.
private struct QuotaThenOnDeviceCoach: OnDeviceCoachGenerating {
    let calls: ServerModelCalls
    let insight: AICoachStructuredResponse
    var adaptation: AIWorkoutAdaptationResponse?

    func isAvailable() async -> Bool { true }
    func unavailableReason() async -> String? { nil }

    func generateCoachInsight(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AICoachStructuredResponse {
        await calls.record(useServerModel)
        if useServerModel { throw OnDeviceCoachError.serverQuotaExceeded(resetDate: nil) }
        return insight
    }

    func generateWorkoutAdaptation(
        instructions: String,
        prompt: String,
        useServerModel: Bool
    ) async throws -> AIWorkoutAdaptationResponse {
        guard let adaptation else { throw OnDeviceCoachError.unavailable }
        return adaptation
    }

    func generatePlanAdaptation(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AIWorkoutPlanAdaptationResponse {
        AIWorkoutPlanAdaptationResponse(adaptations: [])
    }

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        ""
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

    @Test("The insight prompt carries the plan, the runner's usual and the next planned run")
    func promptIncludesReferences() async {
        let recorder = PromptRecorder()
        let backend = RecordingOnDeviceCoach(recorder: recorder, insight: sampleStructured())
        let service = AICoachService(onDeviceBackend: backend)

        // 8 km in 2,500 s is 5:12 per km.
        let workout = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 2_500, workoutType: .easy)
        let planned = ScheduledWorkout(
            scheduledDate: Date(),
            workoutType: .easy,
            targetDistanceMeters: 8_000,
            targetPaceLowerBound: 330,
            targetPaceUpperBound: 350
        )
        let next = ScheduledWorkout(
            scheduledDate: Date().addingTimeInterval(86_400 * 2),
            workoutType: .tempo,
            targetDistanceMeters: 6_000
        )
        let history = (1...3).map { day in
            RunWorkout(
                date: Date().addingTimeInterval(-86_400 * Double(day)),
                distanceMeters: 8_000,
                durationSeconds: 2_800,
                workoutType: .easy
            )
        }

        _ = await service.evaluateWithProvider(
            workout: workout,
            recentHistory: history,
            profile: nil,
            provider: .appleOnDevice,
            plannedSession: planned,
            nextPlannedSession: next
        )

        let prompt = await recorder.prompt
        #expect(prompt.contains("What this run was meant to be:"))
        #expect(prompt.contains("Planned: Easy, 8.0 km, at 5:30–5:50 min/km"))
        #expect(prompt.contains("seconds faster than the planned 5:30–5:50 min/km"))
        #expect(prompt.contains("Your last 3 easy runs averaged 5:50 min/km"))
        #expect(prompt.contains("seconds faster per km"))
        #expect(prompt.contains("Next planned run:"))
        #expect(prompt.contains("Tempo, 6.0 km"))
    }

    @Test("Without a plan the prompt says the run was not a planned session")
    func promptWithoutPlan() async {
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
        #expect(prompt.contains("Not a planned session."))
        #expect(prompt.contains("Fewer than 3 recent easy runs"))
        #expect(prompt.contains("Nothing planned yet."))
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

    @Test("Chat hands every partial to the caller, in order, before it returns")
    @MainActor
    func chatForwardsCumulativePartials() async throws {
        let backend = QuotaReportingCoach(status: nil, chatError: nil)
        let service = AICoachService(onDeviceBackend: backend)
        let partials = PartialRecorder()

        let reply = try await service.chatWithProvider(
            provider: .applePrivateCloud,
            context: "",
            messages: [],
            onPartialText: { partials.record($0) }
        )

        #expect(reply == "Keep your easy runs easy.")

        // No waiting or polling here, and that is the assertion: the updates are awaited
        // on the way through, so all of them have landed by the time the call returns.
        // The fire-and-forget `Task` this replaced could not promise that, which is why
        // the reply arrived in one jump instead of growing.
        #expect(partials.texts == [
            "Keep your",
            "Keep your easy runs",
            "Keep your easy runs easy."
        ])

        // Each partial contains the one before it rather than continuing it: a view that
        // appended these would render "Keep yourKeep your easy runs…".
        #expect(partials.texts.last == reply)
    }

    // MARK: - What the read judges a run against

    private func split(_ index: Int, _ pace: Double, hr: Double? = nil) -> Split {
        Split(
            kilometer: index + 1,
            paceSecondsPerKm: pace,
            heartRate: hr,
            elevationGainMeters: 0,
            cumulativeDistanceMeters: Double(index + 1) * 1_000
        )
    }

    private func segment(_ meters: Double?, _ label: String, pace: Double? = nil) -> WorkoutSegment {
        WorkoutSegment(distanceMeters: meters, durationSeconds: nil, targetPaceSecondsPerKm: pace, label: label)
    }

    private func recordedPrompt(
        workout: RunWorkout,
        recentHistory: [RunWorkout] = [],
        profile: UserProfile? = nil,
        heartRateZones: [HRZoneSlice] = [],
        unitPreference: UnitPreference = .metric,
        plannedSession: ScheduledWorkout? = nil
    ) async -> String {
        let recorder = PromptRecorder()
        let service = AICoachService(
            onDeviceBackend: RecordingOnDeviceCoach(recorder: recorder, insight: sampleStructured())
        )
        _ = await service.evaluateWithProvider(
            workout: workout,
            recentHistory: recentHistory,
            profile: profile,
            provider: .appleOnDevice,
            heartRateZones: heartRateZones,
            unitPreference: unitPreference,
            plannedSession: plannedSession
        )
        return await recorder.prompt
    }

    @Test("A tempo run to plan is judged on its tempo block, not on its whole-run average")
    func tempoIsJudgedOnItsBlock() async {
        // 2 km warm-up at 6:00, 5 km at 4:50, 2 km cool-down: exactly the plan, and a
        // 5:21 average that used to read "26 seconds slower than the planned 4:45–4:55".
        let paces: [Double] = [360, 360, 290, 290, 290, 290, 290, 360, 360]
        // `.easy` is what the Watch import infers from that average.
        let workout = RunWorkout(date: Date(), distanceMeters: 9_000, durationSeconds: paces.reduce(0, +), workoutType: .easy)
        workout.splits = paces.enumerated().map { index, pace in split(index, pace) }
        let planned = ScheduledWorkout(
            scheduledDate: Date(),
            workoutType: .tempo,
            targetDistanceMeters: 9_000,
            targetPaceLowerBound: 285,
            targetPaceUpperBound: 295
        )
        planned.workoutStructure = WorkoutStructure(
            warmup: segment(2_000, "Warm-up"),
            mainSets: [
                WorkoutSet(
                    repetitions: 1,
                    workSegment: segment(5_000, "Tempo", pace: 290),
                    recoverySegment: segment(nil, "Recovery jog"),
                    label: "Tempo Block"
                )
            ],
            cooldown: segment(2_000, "Cool-down"),
            totalEstimatedDistanceMeters: 9_000,
            totalEstimatedDurationSeconds: 2_890
        )

        let prompt = await recordedPrompt(workout: workout, plannedSession: planned)

        #expect(prompt.contains("Type: Tempo"))
        #expect(prompt.contains("The fastest 4.0 km of splits ran 4:50 min/km, inside the planned 4:45–4:55 min/km."))
        #expect(!prompt.contains("seconds slower than the planned"))
        #expect(prompt.contains("These splits mix the work with the easy running around it"))
        #expect(prompt.contains("Fewer than 3 recent tempo runs"))
    }

    @Test("An interval session imported as an easy run is read as intervals")
    func intervalsAreNotReadAsAnEasyRun() async {
        let profile = UserProfile(
            name: "Runner",
            goalRace: .fiveK,
            goalFinishTime: 1_500,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )
        profile.maxHeartRateBPM = 190
        let workout = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 2_390, workoutType: .easy)
        // Heart rate climbs from the warm-up to the last rep, as it should.
        let laps: [(Double, Double)] = [
            (345, 128), (330, 140), (260, 165), (300, 160), (255, 172), (300, 168), (250, 178), (350, 170)
        ]
        workout.splits = laps.enumerated().map { index, lap in split(index, lap.0, hr: lap.1) }
        let planned = ScheduledWorkout(
            scheduledDate: Date(),
            workoutType: .interval,
            targetDistanceMeters: 8_000,
            targetPaceLowerBound: 240,
            targetPaceUpperBound: 250
        )
        let zones = HeartRateZoneService.timeInZones(
            bpmSamples: [130, 160, 170, 175, 178, 165],
            totalSeconds: workout.durationSeconds,
            maxHR: 190
        )

        let prompt = await recordedPrompt(
            workout: workout,
            profile: profile,
            heartRateZones: zones,
            plannedSession: planned
        )

        #expect(prompt.contains("Type: Interval"))
        #expect(prompt.contains("is the pace for the work, not the whole run"))
        #expect(!prompt.contains("seconds slower than the planned"))
        // Neither the climb nor the time at threshold is a problem in an interval session.
        #expect(!prompt.contains("Heart-rate drift"))
        #expect(!prompt.contains("Hold the next"))
    }

    @Test("An easy run is held against the usual easy run, not the recent quality sessions")
    func easyRunIsComparedWithEasyRuns() async {
        // 6:20 per km, against easy runs at 5:50 and tempo runs at 4:50.
        let workout = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 3_040, workoutType: .easy)
        let easy = (1...3).map { day in
            RunWorkout(date: Date().addingTimeInterval(-86_400 * Double(day)), distanceMeters: 8_000, durationSeconds: 2_800, workoutType: .easy)
        }
        let tempo = (4...6).map { day in
            RunWorkout(date: Date().addingTimeInterval(-86_400 * Double(day)), distanceMeters: 8_000, durationSeconds: 2_320, workoutType: .tempo)
        }

        let prompt = await recordedPrompt(workout: workout, recentHistory: easy + tempo)

        #expect(prompt.contains("This run was slower than your usual easy run."))
        #expect(!prompt.contains("quality baseline"))
        #expect(!prompt.contains("Prioritize recovery"))
    }

    @Test("Zones from an age-estimated max heart rate do not call an easy run too hard")
    func estimatedZonesDoNotFlagAnEasyRun() async {
        let workout = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 2_800, workoutType: .easy)
        let zones = HeartRateZoneService.timeInZones(
            bpmSamples: [150, 160, 165, 168],
            totalSeconds: workout.durationSeconds,
            maxHR: 185
        )

        let estimated = await recordedPrompt(workout: workout, heartRateZones: zones)
        #expect(!estimated.contains("Hold the next"))

        let profile = UserProfile(
            name: "Runner",
            goalRace: .fiveK,
            goalFinishTime: 1_500,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )
        profile.maxHeartRateBPM = 185
        let measured = await recordedPrompt(workout: workout, profile: profile, heartRateZones: zones)
        #expect(measured.contains("Hold the next easy run by effort in Z1–Z2"))
    }

    @Test("The prompt names the runner's unit")
    func promptNamesTheUnit() async {
        let workout = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 2_500, workoutType: .easy)

        let miles = await recordedPrompt(workout: workout, unitPreference: .imperial)
        #expect(miles.contains("Units: miles: write every pace per mile and every distance in miles."))

        let kilometres = await recordedPrompt(workout: workout)
        #expect(kilometres.contains("Units: kilometres: write every pace per km and every distance in km."))
    }

    @Test("A run read that hits the Private Cloud Compute quota is written on-device instead")
    func insightFallsBackOnDeviceOnQuota() async {
        let calls = ServerModelCalls()
        let service = AICoachService(
            onDeviceBackend: QuotaThenOnDeviceCoach(calls: calls, insight: sampleStructured())
        )
        let workout = RunWorkout(date: Date(), distanceMeters: 8_000, durationSeconds: 2_500, workoutType: .easy)

        let insight = await service.evaluateWithProvider(
            workout: workout,
            recentHistory: [],
            profile: nil,
            provider: .applePrivateCloud
        )

        #expect(insight.apiReady)
        #expect(insight.headline == "Strong Negative Split")
        #expect(await calls.flags == [true, false])
    }

    @Test("An adaptation keeps the targets the model left out")
    func adaptationKeepsOmittedTargets() async throws {
        let profile = UserProfile(
            name: "Runner",
            goalRace: .halfMarathon,
            goalFinishTime: 6_300,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate
        )
        func adapted(type: String) async -> ScheduledWorkout? {
            let scheduled = ScheduledWorkout(
                scheduledDate: Date().addingTimeInterval(86_400),
                workoutType: .tempo,
                targetDistanceMeters: 8_000,
                targetPaceLowerBound: 285,
                targetPaceUpperBound: 295
            )
            let backend = QuotaThenOnDeviceCoach(
                calls: ServerModelCalls(),
                insight: sampleStructured(),
                adaptation: AIWorkoutAdaptationResponse(
                    workoutType: type,
                    targetDistanceMeters: nil,
                    targetPaceLowerBound: nil,
                    targetPaceUpperBound: nil,
                    explanation: "Keep the tempo controlled after a hard week.",
                    intervals: [],
                    workoutStructure: nil
                )
            )
            return await AICoachService(onDeviceBackend: backend).adaptScheduledWorkoutWithProvider(
                scheduled: scheduled,
                recentHistory: [],
                profile: profile,
                provider: .appleOnDevice
            )
        }

        let sameType = try #require(await adapted(type: "Tempo"))
        #expect(sameType.workoutType == .tempo)
        #expect(sameType.targetDistanceMeters == 8_000)
        #expect(sameType.targetPaceLowerBound == 285)
        #expect(sameType.targetPaceUpperBound == 295)

        // A tempo pace is no target for an easy run, so it goes with the type.
        let easier = try #require(await adapted(type: "Easy"))
        #expect(easier.workoutType == .easy)
        #expect(easier.targetDistanceMeters == 8_000)
        #expect(easier.targetPaceRange == nil)
    }
}

/// Collects the partial texts a streaming call publishes.
///
/// Main-actor isolated because that is where the callback is delivered — the same place
/// a view would be writing its state from.
@MainActor
private final class PartialRecorder {
    private(set) var texts: [String] = []

    func record(_ text: String) {
        texts.append(text)
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
