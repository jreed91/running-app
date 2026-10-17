import Foundation

/// A runner's thumbs-up/down on a coach insight.
///
/// Lives here rather than inside the run-summary view because it is persisted on the
/// run (N22): the row used to write to view state that nothing read, so the rating
/// vanished the moment the screen was dismissed.
enum AICoachReaction: String, Codable, Sendable {
    case up
    case down
}

struct AICoachInsight: Codable, Sendable {
    let headline: String
    let summary: String
    let fullAnalysis: String?
    let confidence: Int
    let evidence: [AICoachEvidenceItem]
    let actionItems: [AICoachActionItem]
    let focusAreas: [String]
    let nextWorkoutSuggestion: String
    let nextWorkoutRationale: String?
    let apiReady: Bool
}

struct AICoachEvidenceItem: Codable, Hashable, Sendable {
    let label: String
    let value: String
    let delta: String?
    let tone: String

    init(label: String, value: String, delta: String?, tone: String) {
        self.label = label
        self.value = value
        self.delta = delta
        self.tone = tone
    }
}

struct AICoachActionItem: Codable, Hashable, Sendable {
    let title: String
    let detail: String
    let priority: String
    let metric: String?
    let tone: String?

    init(title: String, detail: String, priority: String, metric: String?, tone: String?) {
        self.title = title
        self.detail = detail
        self.priority = priority
        self.metric = metric
        self.tone = tone
    }
}

/// The coach's analysis in the shape the UI consumes.
///
/// Once produced by parsing free-form model JSON; now only ever built by the
/// Foundation Models backend's guided generation (`GeneratedCoachInsight`). The
/// tolerant `Decodable` machinery that went with the JSON path — flexible
/// string/int coercion, alternate `action_items`/`actions` keys, per-field defaults —
/// had no remaining caller and has been removed (N28).
struct AICoachStructuredResponse: Sendable {
    struct NextWorkout: Sendable {
        let title: String
        let rationale: String

        init(title: String, rationale: String) {
            self.title = title
            self.rationale = rationale
        }
    }

    let headline: String
    let summary: String
    let fullAnalysis: String?
    let confidence: Int
    let evidence: [AICoachEvidenceItem]
    let actionItems: [AICoachActionItem]
    let nextWorkout: NextWorkout

    init(
        headline: String,
        summary: String,
        fullAnalysis: String?,
        confidence: Int,
        evidence: [AICoachEvidenceItem],
        actionItems: [AICoachActionItem],
        nextWorkout: NextWorkout
    ) {
        self.headline = headline
        self.summary = summary
        self.fullAnalysis = fullAnalysis
        self.confidence = confidence
        self.evidence = evidence
        self.actionItems = actionItems
        self.nextWorkout = nextWorkout
    }
}

struct AIWorkoutAdaptationResponse: Codable, Sendable {
    let workoutType: String
    let targetDistanceMeters: Double?
    let targetPaceLowerBound: Double?
    let targetPaceUpperBound: Double?
    let explanation: String
    let intervals: [AIWorkoutAdaptationInterval]
    let workoutStructure: AIWorkoutStructure?

    enum CodingKeys: String, CodingKey {
        case workoutType = "workout_type"
        case targetDistanceMeters = "target_distance_meters"
        case targetPaceLowerBound = "target_pace_lower_bound"
        case targetPaceUpperBound = "target_pace_upper_bound"
        case explanation
        case intervals
        case workoutStructure = "workout_structure"
    }
}

struct AIWorkoutPlanAdaptationResponse: Codable, Sendable {
    let adaptations: [AIWorkoutPlanAdaptation]
}

struct AIWorkoutPlanAdaptation: Codable, Sendable {
    let workoutID: String
    let workoutType: String
    let targetDistanceMeters: Double?
    let targetPaceLowerBound: Double?
    let targetPaceUpperBound: Double?
    let explanation: String
    let intervals: [AIWorkoutAdaptationInterval]
    let workoutStructure: AIWorkoutStructure?

    enum CodingKeys: String, CodingKey {
        case workoutID = "workout_id"
        case workoutType = "workout_type"
        case targetDistanceMeters = "target_distance_meters"
        case targetPaceLowerBound = "target_pace_lower_bound"
        case targetPaceUpperBound = "target_pace_upper_bound"
        case explanation
        case intervals
        case workoutStructure = "workout_structure"
    }

    var adaptation: AIWorkoutAdaptationResponse {
        AIWorkoutAdaptationResponse(
            workoutType: workoutType,
            targetDistanceMeters: targetDistanceMeters,
            targetPaceLowerBound: targetPaceLowerBound,
            targetPaceUpperBound: targetPaceUpperBound,
            explanation: explanation,
            intervals: intervals,
            workoutStructure: workoutStructure
        )
    }
}

struct AIWorkoutAdaptationInterval: Codable, Sendable {
    let repetitions: Int
    let distanceMeters: Double?
    let durationSeconds: Double?
    let targetPaceSecondsPerKm: Double?
    let recoverySeconds: Double
    let recoveryType: String

    enum CodingKeys: String, CodingKey {
        case repetitions
        case distanceMeters = "distance_meters"
        case durationSeconds = "duration_seconds"
        case targetPaceSecondsPerKm = "target_pace_seconds_per_km"
        case recoverySeconds = "recovery_seconds"
        case recoveryType = "recovery_type"
    }
}

struct AIWorkoutStructure: Codable, Sendable {
    let warmup: AIWorkoutSegment
    let mainSets: [AIWorkoutSet]
    let cooldown: AIWorkoutSegment
    let totalEstimatedDistanceMeters: Double
    let totalEstimatedDurationSeconds: Double

    enum CodingKeys: String, CodingKey {
        case warmup
        case mainSets = "main_sets"
        case cooldown
        case totalEstimatedDistanceMeters = "total_estimated_distance_meters"
        case totalEstimatedDurationSeconds = "total_estimated_duration_seconds"
    }
}

struct AIWorkoutSet: Codable, Sendable {
    let repetitions: Int
    let workSegment: AIWorkoutSegment
    let recoverySegment: AIWorkoutSegment
    let label: String

    enum CodingKeys: String, CodingKey {
        case repetitions
        case workSegment = "work_segment"
        case recoverySegment = "recovery_segment"
        case label
    }
}

struct AIWorkoutSegment: Codable, Sendable {
    let distanceMeters: Double?
    let durationSeconds: Double?
    let targetPaceSecondsPerKm: Double?
    let label: String

    enum CodingKeys: String, CodingKey {
        case distanceMeters = "distance_meters"
        case durationSeconds = "duration_seconds"
        case targetPaceSecondsPerKm = "target_pace_seconds_per_km"
        case label
    }
}

/// A single turn in a coaching conversation, passed to the on-device model.
struct AIProviderChatMessage: Sendable {
    let role: String
    let content: String
}

struct AICoachService: Sendable {
    let onDeviceBackend: (any OnDeviceCoachGenerating)?

    init(
        onDeviceBackend: (any OnDeviceCoachGenerating)? = OnDeviceCoachFactory.makeDefault()
    ) {
        self.onDeviceBackend = onDeviceBackend
    }

    /// Availability and daily-quota state of Apple's Private Cloud Compute model, or `nil`
    /// when this device has no server model. Settings renders it so the runner sees their
    /// standing before a request fails, which is how Apple asks apps to handle the quota.
    func serverModelStatus() async -> ServerModelStatus? {
        guard let backend = onDeviceBackend else { return nil }
        return await backend.serverModelStatus()
    }

    /// Presents the system's iCloud+ upgrade flow for a larger daily PCC allowance.
    @MainActor
    func presentServerLimitIncrease() {
        onDeviceBackend?.presentLimitIncrease()
    }

    /// - Parameter onPartialText: the reply as written so far, delivered repeatedly while
    ///   the coach writes. Each call supersedes the last (see `OnDeviceCoachGenerating`),
    ///   so the chat renders the value it is handed rather than appending it.
    func chatWithProvider(
        provider: AIProvider,
        context: String,
        messages: [AIProviderChatMessage],
        onPartialText: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        guard let backend = onDeviceBackend, await backend.isAvailable() else {
            throw OnDeviceCoachError.unavailable
        }
        return try await backend.generateChatReply(
            instructions: Self.chatInstructions,
            context: context,
            messages: messages,
            useServerModel: provider.usesPrivateCloudCompute,
            onPartialText: onPartialText
        )
    }

    /// The model's own wording for the dashboard's Coach Tips, checked against the cards
    /// it was written from; empty when there is no model or the request fails, which
    /// leaves every card on its hard-coded copy. See `CoachTipRewriter`.
    ///
    /// Runs on the runner's chosen model, so Private Cloud Compute by default. Once the
    /// daily PCC allowance is used up the tips are retried on-device rather than left on
    /// the hard-coded copy: nobody asked for these, so unlike the chat there is no one to
    /// tell about the quota, and the Settings status already shows it.
    func writeCoachTips(for cards: [SmartCoachCard], provider: AIProvider) async -> [CoachTipWording] {
        guard !cards.isEmpty, let backend = onDeviceBackend, await backend.isAvailable() else {
            return []
        }
        let prompt = CoachTipRewriter.prompt(for: cards)
        do {
            let drafts: [CoachTipDraft]
            do {
                drafts = try await backend.generateCoachTips(
                    instructions: CoachTipRewriter.instructions,
                    prompt: prompt,
                    useServerModel: provider.usesPrivateCloudCompute
                )
            } catch OnDeviceCoachError.serverQuotaExceeded(_) {
                drafts = try await backend.generateCoachTips(
                    instructions: CoachTipRewriter.instructions,
                    prompt: prompt,
                    useServerModel: false
                )
            }
            return CoachTipRewriter.validated(drafts, for: cards)
        } catch {
            return []
        }
    }

    /// - Parameter heartRateZones: this run's time-in-zone breakdown, as shown on the run
    ///   summary. Passed in rather than derived here because computing it needs the runner's
    ///   max HR and, for older imported runs, a HealthKit backfill the view already owns.
    @MainActor
    func evaluateWithProvider(
        workout: RunWorkout,
        recentHistory: [RunWorkout],
        profile: UserProfile?,
        provider: AIProvider,
        heartRateZones: [HRZoneSlice] = [],
        unitPreference: UnitPreference = .metric,
        plannedSession: ScheduledWorkout? = nil,
        nextPlannedSession: ScheduledWorkout? = nil,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> AICoachInsight {
        let context = makePromptContext(
            workout: workout,
            recentHistory: recentHistory,
            profile: profile,
            heartRateZones: heartRateZones,
            unitPreference: unitPreference
        )
        let details = makeWorkoutDetails(
            workout: workout,
            recentHistory: recentHistory,
            profile: profile,
            heartRateZones: heartRateZones,
            unitPreference: unitPreference,
            plannedSession: plannedSession,
            nextPlannedSession: nextPlannedSession
        )

        // Apple's on-device / Private Cloud Compute model: no key required.
        if let backend = onDeviceBackend, await backend.isAvailable() {
            do {
                let prompt = Self.insightPrompt(
                    summary: context.summary,
                    focusAreas: context.focusAreas,
                    details: details
                )
                let structured = try await backend.generateCoachInsight(
                    instructions: Self.insightInstructions,
                    prompt: prompt,
                    useServerModel: provider.usesPrivateCloudCompute,
                    onPartialText: onPartialText
                )
                return makeInsight(from: structured, provider: provider)
            } catch {
                return localHeuristicInsight(context: context, provider: provider)
            }
        }
        // Model unavailable: degrade to the locally-computed analysis rather than a dead-end.
        return localHeuristicInsight(context: context, provider: provider)
    }

    private func makeInsight(from structured: AICoachStructuredResponse, provider: AIProvider) -> AICoachInsight {
        AICoachInsight(
            headline: structured.headline.isEmpty ? "\(provider.displayName) Analysis" : structured.headline,
            summary: structured.summary,
            fullAnalysis: structured.fullAnalysis,
            confidence: min(max(structured.confidence, 0), 100),
            evidence: Array(structured.evidence.prefix(3)),
            actionItems: Array(structured.actionItems.prefix(3)),
            focusAreas: structured.actionItems.map(\.title),
            nextWorkoutSuggestion: structured.nextWorkout.title,
            nextWorkoutRationale: structured.nextWorkout.rationale,
            apiReady: true
        )
    }

    /// Surfaces the locally-computed run analysis (pace/HR drift, conditions, baseline)
    /// as a non-model insight when Apple's model is unavailable. Always shows something
    /// useful instead of an "AI unavailable" dead-end.
    private func localHeuristicInsight(
        context: (summary: String, focusAreas: [String]),
        provider: AIProvider
    ) -> AICoachInsight {
        let actions = context.focusAreas.prefix(3).map {
            AICoachActionItem(title: "Focus", detail: $0, priority: "Medium", metric: nil, tone: "neutral")
        }
        return AICoachInsight(
            headline: "On-Device Summary",
            summary: context.summary,
            fullAnalysis: nil,
            confidence: 0,
            evidence: [],
            actionItems: Array(actions),
            focusAreas: context.focusAreas,
            nextWorkoutSuggestion: "Keep the next session controlled and consistent.",
            nextWorkoutRationale: nil,
            apiReady: false
        )
    }

    @MainActor
    func adaptScheduledWorkoutWithProvider(
        scheduled: ScheduledWorkout,
        recentHistory: [RunWorkout],
        profile: UserProfile,
        provider: AIProvider,
        unitPreference: UnitPreference = .metric,
        coachFeedback: String? = nil
    ) async -> ScheduledWorkout? {
        guard scheduled.workoutType != .rest,
              scheduled.workoutType != .crossTraining else {
            return scheduled
        }

        let adaptationContext = makeAdaptationContext(
            scheduled: scheduled,
            recentHistory: recentHistory,
            profile: profile,
            unitPreference: unitPreference,
            coachFeedback: coachFeedback
        )

        guard let backend = onDeviceBackend, await backend.isAvailable() else { return nil }
        do {
            let structured = try await backend.generateWorkoutAdaptation(
                instructions: Self.adaptationInstructions,
                prompt: Self.adaptationPrompt(context: adaptationContext),
                useServerModel: provider.usesPrivateCloudCompute
            )
            guard Self.isValidAdaptation(structured),
                  let adapted = makeScheduledWorkout(from: structured, scheduled: scheduled) else {
                return nil
            }
            return adapted
        } catch {
            return nil
        }
    }

    @MainActor
    func adaptScheduledWorkoutsWithProvider(
        scheduled workouts: [ScheduledWorkout],
        recentHistory: [RunWorkout],
        profile: UserProfile,
        provider: AIProvider,
        unitPreference: UnitPreference = .metric,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> [UUID: ScheduledWorkout] {
        let adaptableWorkouts = workouts.filter {
            $0.workoutType != .rest
                && $0.workoutType != .race
                && $0.workoutType != .crossTraining
        }
        guard !adaptableWorkouts.isEmpty else { return [:] }

        let adaptationContext = makePlanAdaptationContext(
            scheduled: adaptableWorkouts,
            recentHistory: recentHistory,
            profile: profile,
            unitPreference: unitPreference
        )

        guard let backend = onDeviceBackend, await backend.isAvailable() else { return [:] }
        let structured = try? await backend.generatePlanAdaptation(
            instructions: Self.planAdaptationInstructions,
            prompt: Self.planAdaptationPrompt(context: adaptationContext),
            useServerModel: provider.usesPrivateCloudCompute,
            onPartialText: onPartialText
        )

        guard let structured else { return [:] }

        var adaptedByID: [UUID: ScheduledWorkout] = [:]
        for item in structured.adaptations {
            guard let id = UUID(uuidString: item.workoutID),
                  let original = adaptableWorkouts.first(where: { $0.id == id }),
                  Self.isValidAdaptation(item.adaptation),
                  let adapted = makeScheduledWorkout(from: item.adaptation, scheduled: original) else {
                continue
            }
            adaptedByID[id] = adapted
        }
        return adaptedByID
    }

    private static func isValidAdaptation(_ adaptation: AIWorkoutAdaptationResponse) -> Bool {
        let validType = workoutType(from: adaptation.workoutType) != nil
        let hasExplanation = !adaptation.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let validDistance = adaptation.targetDistanceMeters.map { (500...50_000).contains($0) } ?? true
        let validLower = adaptation.targetPaceLowerBound.map { (120...900).contains($0) } ?? true
        let validUpper = adaptation.targetPaceUpperBound.map { (120...900).contains($0) } ?? true
        let validRange = switch (adaptation.targetPaceLowerBound, adaptation.targetPaceUpperBound) {
        case let (lower?, upper?): lower <= upper
        default: true
        }
        let validStructure = adaptation.workoutStructure.map(isValidStructure) ?? true
        return validType && hasExplanation && validDistance && validLower && validUpper && validRange && validStructure
    }

    private static func isValidStructure(_ structure: AIWorkoutStructure) -> Bool {
        guard (500...50_000).contains(structure.totalEstimatedDistanceMeters),
              (60...30_000).contains(structure.totalEstimatedDurationSeconds),
              !structure.mainSets.isEmpty else {
            return false
        }

        let segments = [structure.warmup, structure.cooldown]
            + structure.mainSets.flatMap { [$0.workSegment, $0.recoverySegment] }
        return segments.allSatisfy { segment in
            let validDistance = segment.distanceMeters.map { (0...50_000).contains($0) } ?? true
            let validDuration = segment.durationSeconds.map { (0...30_000).contains($0) } ?? true
            let validPace = segment.targetPaceSecondsPerKm.map { (120...900).contains($0) } ?? true
            return validDistance && validDuration && validPace
        }
    }

    private static func workoutType(from text: String) -> WorkoutType? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "easy": return .easy
        case "tempo": return .tempo
        case "interval": return .interval
        case "long run", "longrun": return .longRun
        default: return nil
        }
    }

    @MainActor
    private func makeScheduledWorkout(
        from adaptation: AIWorkoutAdaptationResponse,
        scheduled: ScheduledWorkout
    ) -> ScheduledWorkout? {
        guard let responseType = Self.workoutType(from: adaptation.workoutType) else { return nil }
        let type = protectedWorkoutType(responseType, for: scheduled.workoutType)

        let adapted = ScheduledWorkout(
            scheduledDate: scheduled.scheduledDate,
            workoutType: type,
            targetDistanceMeters: adaptation.targetDistanceMeters,
            targetPaceLowerBound: adaptation.targetPaceLowerBound,
            targetPaceUpperBound: adaptation.targetPaceUpperBound,
            notes: adaptation.explanation
        )
        // Deliberately NOT setting `adapted.week`: relating an unmanaged model to a
        // managed one auto-inserts it into the SwiftData context, persisting a phantom
        // duplicate workout. Callers copy fields back onto the scheduled workout.
        adapted.workoutLocation = scheduled.workoutLocation
        adapted.intervals = adaptation.intervals.compactMap(\.domainValue)
        adapted.workoutStructure = adaptation.workoutStructure?.domainValue
            ?? fallbackStructure(for: type, adaptation: adaptation, scheduled: scheduled, intervals: adapted.intervals)
        return adapted
    }

    private func fallbackStructure(
        for type: WorkoutType,
        adaptation: AIWorkoutAdaptationResponse,
        scheduled: ScheduledWorkout,
        intervals: [WorkoutInterval]
    ) -> WorkoutStructure {
        let distance = adaptation.targetDistanceMeters
            ?? scheduled.targetDistanceMeters
            ?? scheduled.workoutStructure?.totalEstimatedDistanceMeters
            ?? 5_000
        let pace = midPace(lower: adaptation.targetPaceLowerBound, upper: adaptation.targetPaceUpperBound)
            ?? midPace(lower: scheduled.targetPaceLowerBound, upper: scheduled.targetPaceUpperBound)
            ?? 360
        let easyPace = min(pace + 45, 900)

        switch type {
        case .interval:
            let interval = intervals.first
            let repetitions = max(interval?.repetitions ?? 4, 1)
            let workDistance = interval?.distanceMeters ?? max(400, distance * 0.12)
            let recoverySeconds = interval?.recoverySeconds ?? 90
            let warmupDistance = min(1_500, max(800, distance * 0.20))
            let cooldownDistance = min(1_500, max(600, distance * 0.15))
            let totalDistance = max(distance, warmupDistance + cooldownDistance + (Double(repetitions) * workDistance))
            let intervalSet = WorkoutSet(
                repetitions: repetitions,
                workSegment: WorkoutSegment(distanceMeters: workDistance, durationSeconds: nil, targetPaceSecondsPerKm: interval?.targetPaceSecondsPerKm ?? pace, label: "Interval"),
                recoverySegment: WorkoutSegment(distanceMeters: nil, durationSeconds: recoverySeconds, targetPaceSecondsPerKm: nil, label: "Recovery jog"),
                label: "Interval Set"
            )
            // Only reps - 1 recovery jogs: the last rep is followed by the cool-down.
            let totalDuration = (totalDistance / 1_000 * pace) + intervalSet.totalRecoverySeconds
            return WorkoutStructure(
                warmup: WorkoutSegment(distanceMeters: warmupDistance, durationSeconds: nil, targetPaceSecondsPerKm: easyPace, label: "Warm-up"),
                mainSets: [intervalSet],
                cooldown: WorkoutSegment(distanceMeters: cooldownDistance, durationSeconds: nil, targetPaceSecondsPerKm: easyPace, label: "Cool-down"),
                totalEstimatedDistanceMeters: totalDistance,
                totalEstimatedDurationSeconds: totalDuration
            )
        case .tempo:
            let warmupDistance = distance * 0.15
            let cooldownDistance = distance * 0.10
            let workDistance = max(500, distance - warmupDistance - cooldownDistance)
            return WorkoutStructure(
                warmup: WorkoutSegment(distanceMeters: warmupDistance, durationSeconds: nil, targetPaceSecondsPerKm: easyPace, label: "Warm-up"),
                mainSets: [
                    WorkoutSet(
                        repetitions: 1,
                        workSegment: WorkoutSegment(distanceMeters: workDistance, durationSeconds: nil, targetPaceSecondsPerKm: pace, label: "Tempo"),
                        recoverySegment: WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: ""),
                        label: "Tempo Block"
                    )
                ],
                cooldown: WorkoutSegment(distanceMeters: cooldownDistance, durationSeconds: nil, targetPaceSecondsPerKm: easyPace, label: "Cool-down"),
                totalEstimatedDistanceMeters: distance,
                totalEstimatedDurationSeconds: distance / 1_000 * pace
            )
        case .longRun:
            return continuousStructure(distance: distance, pace: pace, label: "Long Run")
        default:
            return continuousStructure(distance: distance, pace: pace, label: type.displayName)
        }
    }

    private func continuousStructure(distance: Double, pace: Double, label: String) -> WorkoutStructure {
        let warmupDistance = distance * 0.15
        let cooldownDistance = distance * 0.10
        let workDistance = max(500, distance - warmupDistance - cooldownDistance)
        return WorkoutStructure(
            warmup: WorkoutSegment(distanceMeters: warmupDistance, durationSeconds: nil, targetPaceSecondsPerKm: min(pace + 30, 900), label: "Easy start"),
            mainSets: [
                WorkoutSet(
                    repetitions: 1,
                    workSegment: WorkoutSegment(distanceMeters: workDistance, durationSeconds: nil, targetPaceSecondsPerKm: pace, label: label),
                    recoverySegment: WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: ""),
                    label: label
                )
            ],
            cooldown: WorkoutSegment(distanceMeters: cooldownDistance, durationSeconds: nil, targetPaceSecondsPerKm: pace, label: "Cool-down"),
            totalEstimatedDistanceMeters: distance,
            totalEstimatedDurationSeconds: distance / 1_000 * pace
        )
    }

    private func midPace(lower: Double?, upper: Double?) -> Double? {
        switch (lower, upper) {
        case let (lower?, upper?): return (lower + upper) / 2
        case let (lower?, nil): return lower
        case let (nil, upper?): return upper
        default: return nil
        }
    }

    private func protectedWorkoutType(_ responseType: WorkoutType, for scheduledType: WorkoutType) -> WorkoutType {
        if scheduledType == .longRun {
            return .longRun
        }
        if responseType == .longRun {
            return scheduledType
        }
        return responseType
    }

    private func makePromptContext(
        workout: RunWorkout,
        recentHistory: [RunWorkout],
        profile: UserProfile?,
        heartRateZones: [HRZoneSlice],
        unitPreference: UnitPreference
    ) -> (summary: String, focusAreas: [String]) {
        let drift = paceDriftPercent(for: workout)
        let hrDrift = heartRateDrift(for: workout)
        let qualityRuns = recentHistory.filter { $0.workoutType.isQualitySession }
        let averageRecentPace = qualityRuns.isEmpty
            ? nil
            : qualityRuns.reduce(0) { $0 + $1.averagePaceSecondsPerKm } / Double(qualityRuns.count)

        var focus: [String] = []
        var summaryBits: [String] = []

        if let drift {
            let driftPct = Int(drift.rounded())
            if drift <= 3 {
                summaryBits.append("Pacing held steady across the run (about \(driftPct)% drift).")
            } else if drift <= 7 {
                focus.append("Start 3–5 sec/\(unitPreference.distanceLabel) easier for the first 2 splits.")
                summaryBits.append("Pace faded around \(driftPct)% from the opening to the closing splits.")
            } else {
                focus.append("Pace conservatively early and protect form in final third.")
                summaryBits.append("A \(driftPct)% late-run fade suggests a pacing or endurance mismatch.")
            }
        }

        // Cardiac drift rises naturally on longer, harder, hotter, or hillier
        // efforts, so only surface it when it is clearly beyond the normal range
        // for this kind of run instead of flagging routine drift every time.
        if let hrDrift {
            let driftThreshold: Double
            switch workout.workoutType {
            case .interval, .tempo, .race: driftThreshold = 16
            case .longRun: driftThreshold = 14
            default: driftThreshold = 12
            }
            if hrDrift > driftThreshold {
                focus.append("Add easy aerobic volume to rebuild durability before the next hard day.")
                summaryBits.append("Heart-rate drift of \(Int(hrDrift.rounded()))% ran high for a \(workout.workoutType.displayName.lowercased()), hinting at accumulating fatigue.")
            }
        }

        // The split table and the zone breakdown both sit above the coach card on the run
        // summary, so the read has to speak to them.
        let breakdown = breakdownContext(
            workout: workout,
            heartRateZones: heartRateZones,
            // The pace-drift bit above already frames the fade, so the half-to-half
            // comparison is only worth repeating when drift was not computed (fewer than
            // four splits).
            includeHalfComparison: drift == nil,
            unitPreference: unitPreference
        )
        summaryBits.append(contentsOf: breakdown.summaryBits)
        focus.append(contentsOf: breakdown.focusAreas)

        if let averageRecentPace {
            let delta = workout.averagePaceSecondsPerKm - averageRecentPace
            if delta < -8 {
                summaryBits.append("This run was faster than your recent quality baseline.")
            } else if delta > 8 {
                focus.append("Prioritize recovery before the next quality day.")
                summaryBits.append("This run was slower than your recent quality baseline.")
            }
        }

        // The runner's own rating is the one thing here they told us rather than a sensor
        // did, and it is what the numbers above cannot say: whether the run felt the way it
        // was meant to. It leads the focus list when it points somewhere.
        if let feel = workout.feel {
            summaryBits.append(RunFeelSignal.runSentence(feel: feel, type: workout.intendedWorkoutType))
            if let feelFocus = RunFeelSignal.runFocus(feel: feel, type: workout.intendedWorkoutType) {
                focus.insert(feelFocus, at: 0)
            }
        }

        // Conditions and terrain are unique to each run, so let them shape the
        // analysis rather than leaning on the same generic talking points.
        if let weather = workout.weather, weather.temperatureCelsius >= 24 {
            summaryBits.append("Warm conditions (\(weather.temperatureString(unit: unitPreference))) likely added cardiovascular strain, so weigh effort by feel over pace.")
        }
        if let elevationGain = workout.elevationGainMeters,
           workout.distanceMeters > 0,
           elevationGain / (workout.distanceMeters / 1_000) >= 15 {
            summaryBits.append("Notable climbing (\(elevationGain.elevationString(unit: unitPreference))) shaped pace and heart rate on this route.")
        }

        if focus.isEmpty {
            focus.append("Keep weekly consistency: 1 long run, 1 quality run, remaining easy.")
        }

        let raceContext = profile.map {
            "Goal: \(raceLabel(race: $0.goalRace, distanceMeters: $0.effectiveRaceDistanceMeters, unitPreference: unitPreference))."
        } ?? ""
        let summary = ([raceContext] + summaryBits)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return (summary: summary.isEmpty ? "No local summary available." : summary, focusAreas: Array(focus.prefix(3)))
    }

    /// Summary sentences and focus items drawn from the run's splits and its time-in-zone
    /// breakdown — the two blocks the run summary shows directly above the coaching read.
    private func breakdownContext(
        workout: RunWorkout,
        heartRateZones: [HRZoneSlice],
        includeHalfComparison: Bool,
        unitPreference: UnitPreference
    ) -> (summaryBits: [String], focusAreas: [String]) {
        var summaryBits: [String] = []
        var focus: [String] = []

        if let trend = CoachRunBreakdown.splitTrend(splits: workout.splits, unit: unitPreference) {
            let splitLabel = workout.splitUnit.distanceLabel
            summaryBits.append(
                includeHalfComparison
                    ? CoachRunBreakdown.splitTrendSentence(trend, splitLabel: splitLabel, unit: unitPreference)
                    : CoachRunBreakdown.splitRangeSentence(trend, splitLabel: splitLabel, unit: unitPreference)
            )
        }

        if let zoneSentence = CoachRunBreakdown.zoneSentence(heartRateZones) {
            summaryBits.append(zoneSentence)
        }

        // Cadence: captured on every run but discarded at finish until A5, so no coaching
        // read — local or model — could ever say anything about form.
        let cadence = workout.averageCadenceStepsPerMinute
        if let cadenceSentence = CoachRunBreakdown.cadenceSentence(cadence) {
            summaryBits.append(cadenceSentence)
        }
        if let cadenceFocus = CoachRunBreakdown.cadenceFocus(cadence, workoutType: workout.workoutType) {
            focus.append(cadenceFocus)
        }

        // An easy or long run that spent a big share of its time at threshold or above is
        // the one zone read that changes the next session's advice.
        if let hardShare = CoachRunBreakdown.hardEffortShare(heartRateZones),
           hardShare >= 0.20,
           workout.workoutType == .easy || workout.workoutType == .longRun {
            focus.append(
                "Hold the next \(workout.workoutType.displayName.lowercased()) by effort in Z1–Z2 — "
                    + "\(Int((hardShare * 100).rounded()))% of this one sat at threshold or harder."
            )
        }

        return (summaryBits: summaryBits, focusAreas: focus)
    }

    /// A label for the goal race that appends the concrete distance for
    /// custom-distance goals (e.g. "Custom Distance (10.0 km)"), so the model
    /// knows the actual target rather than just "Custom Distance".
    private func raceLabel(
        race: RaceType,
        distanceMeters: Double,
        unitPreference: UnitPreference
    ) -> String {
        guard race.usesCustomDistance else { return race.displayName }
        return "\(race.displayName) (\(distanceMeters.distanceString(unit: unitPreference)))"
    }

    @MainActor
    private func makeAdaptationContext(
        scheduled: ScheduledWorkout,
        recentHistory: [RunWorkout],
        profile: UserProfile,
        unitPreference: UnitPreference,
        coachFeedback: String? = nil
    ) -> String {
        let date = scheduled.scheduledDate.formatted(date: .abbreviated, time: .omitted)
        let weekday = scheduled.scheduledDate.formatted(.dateTime.weekday(.wide))
        let distance = scheduled.targetDistanceMeters?.distanceString(unit: unitPreference) ?? "open"
        let paceRange: String
        if let range = scheduled.targetPaceRange {
            paceRange = "\(range.lowerBound.paceString(unit: unitPreference))-\(range.upperBound.paceString(unit: unitPreference))"
        } else {
            paceRange = "none"
        }
        let plan = scheduled.week?.plan
        let planRace = plan.map { raceLabel(race: $0.targetRace, distanceMeters: $0.effectiveRaceDistanceMeters, unitPreference: unitPreference) }
            ?? raceLabel(race: profile.goalRace, distanceMeters: profile.effectiveRaceDistanceMeters, unitPreference: unitPreference)
        let goalTime = (plan?.goalTimeSeconds ?? profile.goalFinishTime).durationString
        let phase = scheduled.week?.phase.displayName ?? "Unknown"
        let weekNumber = scheduled.week.map { "\($0.weekNumber)" } ?? "Unknown"
        let weekTarget = scheduled.week?.targetDistanceKm.distanceStringFromKm(unit: unitPreference) ?? "Unknown"
        let selectedRunDays = preferredRunDayNames(for: profile)
        let weekLongRunDays = longRunDayNames(in: scheduled.week)
        let planLongRunDays = longRunDayNames(in: plan)
        let structure = scheduled.workoutStructure.map {
            describeStructure($0, unitPreference: unitPreference)
        } ?? "No structured workout."
        let intervals = scheduled.intervals.isEmpty
            ? "No interval prescription."
            : scheduled.intervals.map { interval in
                let distance = interval.distanceMeters?.distanceString(unit: unitPreference) ?? "open"
                let pace = interval.targetPaceSecondsPerKm?.paceString(unit: unitPreference) ?? "open"
                return "\(interval.repetitions)x \(distance) at \(pace), recovery \(interval.recoverySeconds.durationString)"
            }.joined(separator: "\n")

        // Runs only: these rows are the evidence the model re-paces a session from, and
        // an imported walk in them reads as a run taken at half speed (N38).
        let recent = recentHistory.runsOnly.prefix(8).map { run in
            let avgHR = run.averageHeartRate.map { "\(Int($0)) bpm" } ?? "n/a"
            // swiftlint:disable:next line_length
            return "\(run.date.formatted(date: .abbreviated, time: .omitted)) | \(run.workoutType.displayName) | \(run.distanceMeters.distanceString(unit: unitPreference)) | avg pace \(run.averagePaceSecondsPerKm.paceString(unit: unitPreference)) | duration \(run.durationSeconds.durationString) | avg HR \(avgHR)\(RunFeelSignal.historySuffix(for: run.feel))"
        }.joined(separator: "\n")
        let feelTrend = Self.feelTrendSection(recentHistory)

        return """
        Target race: \(planRace)
        Goal time: \(goalTime)
        Fitness level: \(profile.fitnessLevel.displayName)
        Weekly run days: \(profile.weeklyRunDays)
        Selected running days: \(selectedRunDays)
        Planned long-run days this week: \(weekLongRunDays)
        Planned long-run days across plan: \(planLongRunDays)
        Training week: \(weekNumber)
        Training phase: \(phase)
        Week target volume: \(weekTarget)
        Unit preference for display: \(unitPreference.rawValue)

        Scheduled workout:
        Date: \(date)
        Weekday: \(weekday)
        Type: \(scheduled.workoutType.displayName)
        Distance: \(distance)
        Pace range: \(paceRange)
        Current notes: \(scheduled.notes ?? "none")

        Current structure:
        \(structure)

        Current intervals:
        \(intervals)

        Recent completed runs:
        \(recent.isEmpty ? "No recent completed runs." : recent)

        \(feelTrend)

        \(coachFeedback.map { "Coach feedback to incorporate:\n\($0)" } ?? "")
        """
    }

    @MainActor
    private func makePlanAdaptationContext(
        scheduled workouts: [ScheduledWorkout],
        recentHistory: [RunWorkout],
        profile: UserProfile,
        unitPreference: UnitPreference
    ) -> String {
        let plan = workouts.first?.week?.plan
        let planRace = plan.map { raceLabel(race: $0.targetRace, distanceMeters: $0.effectiveRaceDistanceMeters, unitPreference: unitPreference) }
            ?? raceLabel(race: profile.goalRace, distanceMeters: profile.effectiveRaceDistanceMeters, unitPreference: unitPreference)
        let goalTime = (plan?.goalTimeSeconds ?? profile.goalFinishTime).durationString
        let selectedRunDays = preferredRunDayNames(for: profile)
        let planLongRunDays = longRunDayNames(in: plan)
        let recent = recentHistory.runsOnly.prefix(8).map { run in
            let avgHR = run.averageHeartRate.map { "\(Int($0)) bpm" } ?? "n/a"
            return "\(run.date.formatted(date: .abbreviated, time: .omitted)) | \(run.workoutType.displayName) | \(run.distanceMeters.distanceString(unit: unitPreference)) | pace \(run.averagePaceSecondsPerKm.paceString(unit: unitPreference)) | \(run.durationSeconds.durationString) | HR \(avgHR)\(RunFeelSignal.historySuffix(for: run.feel))"
        }.joined(separator: "\n")
        let feelTrend = Self.feelTrendSection(recentHistory)
        let workoutRows = workouts.map { workout in
            let date = workout.scheduledDate.formatted(date: .abbreviated, time: .omitted)
            let weekday = workout.scheduledDate.formatted(.dateTime.weekday(.abbreviated))
            let distance = workout.targetDistanceMeters?.distanceString(unit: unitPreference) ?? "open"
            let paceRange: String
            if let range = workout.targetPaceRange {
                paceRange = "\(range.lowerBound.paceString(unit: unitPreference))-\(range.upperBound.paceString(unit: unitPreference))"
            } else {
                paceRange = "none"
            }
            let intervals = workout.intervals.isEmpty
                ? ""
                : " | intervals \(workout.intervals.map { "\($0.repetitions)x \($0.distanceMeters?.distanceString(unit: unitPreference) ?? "open") rec \($0.recoverySeconds.durationString)" }.joined(separator: "; "))"
            return """
            \(workout.id.uuidString) | \(date) \(weekday) | week \(workout.week?.weekNumber ?? 0) \(workout.week?.phase.displayName ?? "Unknown") | \(workout.workoutType.displayName) | \(distance) | pace \(paceRange)\(intervals) | notes \(workout.notes ?? "none")
            """
        }.joined(separator: "\n")

        return """
        Adapt these \(workouts.count) scheduled workouts as one coordinated plan update.
        Preserve the exact workout IDs so Stride can apply your response.
        Keep output compact; Stride will build workout structures locally.

        Athlete:
        Target race: \(planRace)
        Goal time: \(goalTime)
        Fitness level: \(profile.fitnessLevel.displayName)
        Weekly run days: \(profile.weeklyRunDays)
        Selected running days: \(selectedRunDays)
        Planned long-run days: \(planLongRunDays)
        Unit preference for display: \(unitPreference.rawValue)

        Recent completed runs:
        \(recent.isEmpty ? "No recent completed runs." : recent)

        \(feelTrend)

        Scheduled workouts:
        \(workoutRows)
        """
    }

    /// How the runner's recent ratings read, for the adaptation prompts. Sits in its own
    /// section after the history block rather than inside it, so `CoachPromptBudget` —
    /// which trims that block row by row — never cuts it in half. Always a line, even with
    /// nothing to report, so the model is not left to guess what a missing rating means.
    static func feelTrendSection(_ history: [RunWorkout], now: Date = Date()) -> String {
        let ratings = history.runsOnly.compactMap(\.feelRating)
        let read = RunFeelSignal.trendSentence(ratings, now: now)
            ?? (ratings.isEmpty
                ? "The runner has not rated how any recent runs felt."
                : "Recent ratings are in line with what each session was meant to feel like.")
        return "How recent runs felt:\n\(read)"
    }

    private func preferredRunDayNames(for profile: UserProfile) -> String {
        let days = profile.preferredRunDayIndices.isEmpty
            ? Array(0..<max(profile.weeklyRunDays, 1))
            : profile.preferredRunDayIndices
        return days.map(weekdayName(forRunDayIndex:)).joined(separator: ", ")
    }

    private func longRunDayNames(in week: TrainingWeek?) -> String {
        guard let week else { return "Unknown" }
        let days = (week.workouts ?? [])
            .filter { $0.workoutType == .longRun }
            .map { Calendar.current.component(.weekday, from: $0.scheduledDate) }
        return dayNames(fromCalendarWeekdays: days)
    }

    private func longRunDayNames(in plan: TrainingPlan?) -> String {
        guard let plan else { return "Unknown" }
        let days = (plan.weeks ?? [])
            .flatMap { $0.workouts ?? [] }
            .filter { $0.workoutType == .longRun }
            .map { Calendar.current.component(.weekday, from: $0.scheduledDate) }
        return dayNames(fromCalendarWeekdays: days)
    }

    private func dayNames(fromCalendarWeekdays weekdays: [Int]) -> String {
        let uniqueDays = Array(Set(weekdays)).sorted()
        guard !uniqueDays.isEmpty else { return "None" }
        return uniqueDays.map { Calendar.current.weekdaySymbols[$0 - 1] }.joined(separator: ", ")
    }

    private func weekdayName(forRunDayIndex index: Int) -> String {
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        guard names.indices.contains(index) else { return "Unknown" }
        return names[index]
    }

    private func describeStructure(_ structure: WorkoutStructure, unitPreference: UnitPreference) -> String {
        let sets = structure.mainSets.map { set in
            "\(set.label): \(set.repetitions)x \(describeSegment(set.workSegment, unitPreference: unitPreference)), recovery \(describeSegment(set.recoverySegment, unitPreference: unitPreference))"
        }.joined(separator: "\n")
        return """
        Warmup: \(describeSegment(structure.warmup, unitPreference: unitPreference))
        Main sets:
        \(sets)
        Cooldown: \(describeSegment(structure.cooldown, unitPreference: unitPreference))
        Total: \(structure.totalEstimatedDistanceMeters.distanceString(unit: unitPreference)), \(structure.totalEstimatedDurationSeconds.durationString)
        """
    }

    private func describeSegment(_ segment: WorkoutSegment, unitPreference: UnitPreference) -> String {
        let distance = segment.distanceMeters?.distanceString(unit: unitPreference) ?? "open"
        let duration = segment.durationSeconds?.durationString ?? "open"
        let pace = segment.targetPaceSecondsPerKm?.paceString(unit: unitPreference) ?? "open"
        return "\(segment.label) distance \(distance), duration \(duration), pace \(pace)"
    }

    private func paceDriftPercent(for workout: RunWorkout) -> Double? {
        guard workout.splits.count >= 4 else { return nil }
        let quarter = max(1, workout.splits.count / 4)
        let first = workout.splits.prefix(quarter).reduce(0) { $0 + $1.paceSecondsPerKm } / Double(quarter)
        let last = workout.splits.suffix(quarter).reduce(0) { $0 + $1.paceSecondsPerKm } / Double(quarter)
        guard first > 0 else { return nil }
        return max(0, ((last - first) / first) * 100)
    }

    private func heartRateDrift(for workout: RunWorkout) -> Double? {
        let hrs = workout.splits.compactMap(\.heartRate)
        guard hrs.count >= 4 else { return nil }
        let quarter = max(1, hrs.count / 4)
        let first = hrs.prefix(quarter).reduce(0, +) / Double(quarter)
        let last = hrs.suffix(quarter).reduce(0, +) / Double(quarter)
        guard first > 0 else { return nil }
        return ((last - first) / first) * 100
    }

    private func makeWorkoutDetails(
        workout: RunWorkout,
        recentHistory: [RunWorkout],
        profile: UserProfile?,
        heartRateZones: [HRZoneSlice],
        unitPreference: UnitPreference,
        plannedSession: ScheduledWorkout?,
        nextPlannedSession: ScheduledWorkout?
    ) -> String {
        let date = workout.date.formatted(date: .abbreviated, time: .shortened)
        let avgPace = workout.averagePaceSecondsPerKm.paceString(unit: unitPreference)
        let avgHR = workout.averageHeartRate.map { "\(Int($0)) bpm" } ?? "n/a"
        let maxHR = workout.maxHeartRate.map { "\(Int($0)) bpm" } ?? "n/a"
        let elevation = workout.elevationGainMeters.map { $0.elevationString(unit: unitPreference) } ?? "n/a"
        // The one form signal the app records. Given raw rather than judged — the model has
        // the run's pace and type beside it, which is what makes a number interpretable (A5).
        let cadence = workout.averageCadenceStepsPerMinute
            .map { "\(Int($0.rounded())) spm" } ?? "n/a"
        let weather = workout.weather.map {
            "\($0.conditionDescription), \($0.temperatureString(unit: unitPreference)), humidity \(Int($0.humidityPercent))%"
        } ?? "n/a"
        let feel = workout.feel?.promptDescription ?? "not rated"
        let profileContext = profile.map {
            "Goal race: \(raceLabel(race: $0.goalRace, distanceMeters: $0.effectiveRaceDistanceMeters, unitPreference: unitPreference)), fitness level: \($0.fitnessLevel.displayName), run days/week: \($0.weeklyRunDays)"
        } ?? "No athlete profile available."

        // Splits and zones are what the runner sees immediately above the coach card, so the
        // prompt carries the same two blocks: every split (middle ones dropped only on very
        // long runs), the derived pacing trend, and the time-in-zone table.
        let splitLabel = workout.splitUnit.distanceLabel
        let splitSection = CoachRunBreakdown.splitSection(
            splits: workout.splits,
            unit: unitPreference,
            splitLabel: splitLabel
        )
        let splitTrendSection = CoachRunBreakdown
            .splitTrend(splits: workout.splits, unit: unitPreference)
            .map { CoachRunBreakdown.splitTrendLine($0, splitLabel: splitLabel, unit: unitPreference) }
            ?? "Not enough splits to derive a trend."
        let zoneSection = CoachRunBreakdown.zoneSection(
            heartRateZones,
            maxHR: profile?.effectiveMaxHeartRate.map(Double.init)
        )

        let recent = recentHistory.runsOnly.prefix(5).map { run in
            "\(run.date.formatted(date: .abbreviated, time: .omitted)) • \(run.workoutType.displayName) • \(run.distanceMeters.distanceString(unit: unitPreference)) • \(run.averagePaceSecondsPerKm.paceString(unit: unitPreference))"
                + (run.averageHeartRate.map { " • \(Int($0.rounded())) bpm" } ?? "")
                + (run.feel.map { " • felt \($0.promptName)" } ?? "")
        }.joined(separator: "\n")

        // The references a verdict needs: what this run was meant to be, what is usual for
        // this kind of run, and what comes next. Without them the coach can only restate
        // the totals and fall back on general advice.
        let planSection = plannedSessionSection(plannedSession, workout: workout, unitPreference: unitPreference)
        let sameType = recentHistory.runsOnly
            .filter { $0.id != workout.id && $0.workoutType == workout.workoutType }
            .map {
                CoachRunComparison.Sample(
                    paceSecondsPerKm: $0.averagePaceSecondsPerKm,
                    heartRate: $0.averageHeartRate,
                    distanceMeters: $0.distanceMeters
                )
            }
        let usualSection = CoachRunComparison.baselineLine(
            typeName: workout.workoutType.displayName,
            currentPaceSecondsPerKm: workout.averagePaceSecondsPerKm,
            currentHeartRate: workout.averageHeartRate,
            baseline: CoachRunComparison.baseline(from: sameType),
            unit: unitPreference
        )
        let nextSection = nextPlannedSession.map {
            "\($0.scheduledDate.formatted(.dateTime.weekday(.wide))): "
                + plannedTargetsDescription($0, unitPreference: unitPreference)
        } ?? "Nothing planned yet."
        let recentSection = recent.isEmpty ? "No recent runs." : recent

        return """
        Date: \(date)
        Type: \(workout.workoutType.displayName)
        Distance: \(workout.distanceMeters.distanceString(unit: unitPreference))
        Duration: \(workout.durationSeconds.durationString)
        Avg pace: \(avgPace)
        Avg HR: \(avgHR)
        Max HR: \(maxHR)
        Avg cadence: \(cadence)
        Elevation gain: \(elevation)
        Weather: \(weather)
        How it felt to the runner: \(feel)
        \(profileContext)

        What this run was meant to be:
        \(planSection)

        Compared with your usual:
        \(usualSection)

        Next planned run:
        \(nextSection)

        Splits (one per \(splitLabel)):
        \(splitSection)

        Split trend: \(splitTrendSection)

        Time in heart-rate zones:
        \(zoneSection)

        Recent history:
        \(recentSection)
        """
    }
}

extension AICoachService {

    /// The planned session this run fulfilled, with how the run compared to its targets.
    func plannedSessionSection(
        _ planned: ScheduledWorkout?,
        workout: RunWorkout,
        unitPreference: UnitPreference
    ) -> String {
        guard let planned else {
            return "Not a planned session. Judge it by what a \(workout.workoutType.displayName.lowercased()) run is for."
        }
        var lines = ["Planned: " + plannedTargetsDescription(planned, unitPreference: unitPreference)]
        if let comparison = CoachRunComparison.planLine(
            actualPaceSecondsPerKm: workout.averagePaceSecondsPerKm,
            actualDistanceMeters: workout.distanceMeters,
            targetPaceLower: planned.targetPaceLowerBound,
            targetPaceUpper: planned.targetPaceUpperBound,
            targetDistanceMeters: planned.targetDistanceMeters,
            unit: unitPreference
        ) {
            lines.append("Result: " + comparison)
        }
        return lines.joined(separator: "\n")
    }

    /// A planned session as one line: its type, distance, pace range and main set.
    func plannedTargetsDescription(_ planned: ScheduledWorkout, unitPreference: UnitPreference) -> String {
        var parts = [planned.workoutType.displayName]
        if let distance = planned.targetDistanceMeters, distance > 0 {
            parts.append(distance.distanceString(unit: unitPreference))
        }
        if let range = planned.targetPaceRange {
            parts.append(
                "at \(range.lowerBound.paceValueString(unit: unitPreference))–"
                    + range.upperBound.paceString(unit: unitPreference)
            )
        }
        if let set = planned.workoutStructure?.mainSets.first {
            let work = set.workSegment
            let size = work.distanceMeters?.distanceString(unit: unitPreference)
                ?? work.durationSeconds?.durationString
            if let size {
                parts.append("main set \(set.repetitions) x \(size)")
            }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - On-device prompt + instruction builders
//
// Instructions carry the coaching guidance; the structural rules (counts, ranges,
// field lengths, enum choices) live in the `@Generable` `@Guide` annotations, so these
// strings omit the JSON-schema block the cloud prompts need.
extension AICoachService {
    static let chatInstructions = """
    You are Stride's running coach, talking to one runner in a chat window.

    Write the way a coach talks out loud. Say "you", not "the runner" or "the athlete". \
    Use everyday words and one idea per sentence. Lead with the answer, then give the \
    reason for it.

    Write numbers the way a runner reads them off a watch: paces as minutes and seconds \
    ("5:20 per km"), times in minutes and hours ("42 minutes"), distances to one decimal \
    place. Never write a pace as a count of seconds. The first time you use a training \
    term, explain it in a few words — for example "threshold pace, the effort you could \
    hold for about an hour".

    Keep it under 120 words unless the runner asks for more, and keep paragraphs to two \
    or three sentences. Use a short bullet list when you are genuinely listing separate \
    things; otherwise write prose. No headings and no tables.

    Use only the runner context and this conversation. If something you need is missing, \
    say so plainly and ask for it. Give no medical or clinical advice, and do not claim \
    to be certain when you are not.
    """

    static let insightInstructions = """
    You are a running coach reading back one finished run to the runner who just did it.

    The read fills one screen, in this order: a verdict, one sentence on why, three \
    numbers that prove it, what to do next, and the next run. Build it in that order.

    Decide the verdict first: did this run do the job it was meant to do? If it was a \
    planned session, judge it against the plan's pace and distance. If not, judge it by \
    what that kind of run is for: easy runs easy, long runs steady, quality runs on \
    target. Then check it against the runner's usual for this kind of run: faster at the \
    same heart rate, or the same pace at a lower one, is fitness; faster at a much \
    higher heart rate is just a harder day.

    Choose the three numbers that prove the verdict. Prefer comparisons with the plan or \
    the usual over totals the runner already sees at the top of the screen; a bare \
    distance, time or average pace is not evidence.

    The first thing to do is the single most useful change; the other two must be \
    different from it. If the run went well, say so and keep the advice short. Do not \
    invent a problem to have something to fix.

    For the next run, if one is planned, say whether to do it as planned or how to \
    change it, and why. Do not swap it for a different kind of session unless this run \
    gives you a reason to.

    Write the way a coach talks out loud: say "you", use everyday words, and keep each \
    sentence to one idea. A runner should understand every line on first read without \
    looking anything up. Explain a training term in a few words the first time you use \
    it, and spell out what a number means rather than leaving it to speak for itself.

    Write numbers the way they appear on a watch: paces as minutes and seconds \
    ("5:20 per km"), times in minutes and hours, distances to one decimal place. Name a \
    split by where it was in the run ("the fourth kilometre", "the last mile"), not by \
    an index. Name a heart-rate zone by what it feels like as well as its number \
    ("zone 4, comfortably hard").

    Use only the supplied data, and ground the read in this run: its pace, its splits, \
    its distance, its terrain, its conditions. Use the per-split table, the split trend \
    and the time-in-zone breakdown, so what you say matches the charts the runner is \
    looking at. Say what was distinctive about this session rather than what is true of \
    running in general, and vary what you lead with run to run (how the pacing was \
    executed, the split trend, the zone spread, the structure, the terrain, the \
    conditions, or the recovery it needs).

    If the runner rated how the run felt, take their word for it and square it with the \
    numbers: an easy run that felt hard matters even when the pace looked fine, and a \
    hard session that felt easy is worth saying out loud.

    Treat heart rate as supporting context, not a problem, unless it is clearly and \
    substantially abnormal for this kind of run. Give no medical or clinical advice, and \
    never mention that you are an AI.
    """

    static func insightPrompt(summary: String, focusAreas: [String], details: String) -> String {
        let bullets = focusAreas.map { "- \($0)" }.joined(separator: "\n")
        return """
        Analyse this run and produce coaching feedback.

        Workout summary:
        \(summary)

        Workout details:
        \(details)

        What the app's own checks flagged (use one only if it matters for this run):
        \(bullets)
        """
    }

    static let adaptationInstructions = """
    You are a running coach adapting a single scheduled run, using only the supplied \
    athlete context.

    Keep the workout on its scheduled day and weekday. If the scheduled workout is a \
    long run, keep it a long run; never turn a shorter run into a long run. Tailor \
    volume and intensity to the target race and the current training phase. If the run \
    should not change, return the same targets and explain why.

    Every numeric pace field is in seconds per kilometre, whatever the runner's display \
    unit. The explanation is the opposite: it is read by the runner, so write it the way \
    a coach talks. Say "you", use everyday words, keep it to one or two short sentences, \
    and write paces as minutes and seconds ("5:20 per km") — never as a count of \
    seconds. Say what changed and why it changed.

    Recent runs may carry the runner's own rating of how they felt, on a five-step scale \
    from very easy to very hard. Weigh it alongside pace and heart rate: easy runs that \
    felt hard point to fatigue, so hold or ease intensity rather than add to it; quality \
    sessions that felt easy mean the paces can firm up slightly. One rating is a hint, \
    not a verdict.

    Give no medical or clinical advice, and never mention that you are an AI.
    """

    static func adaptationPrompt(context: String) -> String {
        """
        Adapt the scheduled run using only the athlete and workout context below.

        \(context)
        """
    }

    static let planAdaptationInstructions = """
    You are a running coach adapting several scheduled runs as one coordinated plan \
    update, using only the supplied athlete context.

    Return exactly one adaptation per provided workout id, copying each id exactly. Keep \
    each workout on its scheduled day and weekday. If a scheduled workout is a long run, \
    keep it a long run; never turn a shorter run into a long run. Tailor volume and \
    intensity to the target race and the training phase.

    Every numeric pace field is in seconds per kilometre. The explanation is read by the \
    runner, so write it the way a coach talks: one plain sentence under 120 characters, \
    addressed to "you", saying what changed and why. Write paces there as minutes and \
    seconds ("5:20 per km"), never as a count of seconds.

    Recent runs may carry the runner's own rating of how they felt, on a five-step scale \
    from very easy to very hard. Weigh it alongside pace and heart rate: easy runs that \
    felt hard point to fatigue, so hold or ease intensity rather than add to it; quality \
    sessions that felt easy mean the paces can firm up slightly. One rating is a hint, \
    not a verdict.

    Give no medical or clinical advice, and never mention that you are an AI.
    """

    static func planAdaptationPrompt(context: String) -> String {
        """
        Adapt all scheduled runs in one pass using only the athlete, plan, and workout context below.

        \(context)
        """
    }
}

private extension AIWorkoutAdaptationInterval {
    var domainValue: WorkoutInterval? {
        guard repetitions > 0,
              (distanceMeters != nil || durationSeconds != nil),
              recoverySeconds >= 0 else {
            return nil
        }

        return WorkoutInterval(
            repetitions: repetitions,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            targetPaceSecondsPerKm: targetPaceSecondsPerKm,
            recoverySeconds: recoverySeconds,
            recoveryType: recoveryType.lowercased() == "walk" ? .walk : .jog
        )
    }
}

private extension AIWorkoutStructure {
    var domainValue: WorkoutStructure {
        WorkoutStructure(
            warmup: warmup.domainValue,
            mainSets: mainSets.map(\.domainValue),
            cooldown: cooldown.domainValue,
            totalEstimatedDistanceMeters: totalEstimatedDistanceMeters,
            totalEstimatedDurationSeconds: totalEstimatedDurationSeconds
        )
    }
}

private extension AIWorkoutSet {
    var domainValue: WorkoutSet {
        WorkoutSet(
            repetitions: repetitions,
            workSegment: workSegment.domainValue,
            recoverySegment: recoverySegment.domainValue,
            label: label
        )
    }
}

private extension AIWorkoutSegment {
    var domainValue: WorkoutSegment {
        WorkoutSegment(
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            targetPaceSecondsPerKm: targetPaceSecondsPerKm,
            label: label
        )
    }
}
