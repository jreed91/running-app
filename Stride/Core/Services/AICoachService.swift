import Foundation

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

    enum CodingKeys: String, CodingKey {
        case label
        case value
        case delta
        case tone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = container.decodeFlexibleStringIfPresent(forKey: .label) ?? "Metric"
        value = container.decodeFlexibleStringIfPresent(forKey: .value) ?? "N/A"
        delta = container.decodeFlexibleStringIfPresent(forKey: .delta)
        tone = container.decodeFlexibleStringIfPresent(forKey: .tone) ?? "neutral"
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

    enum CodingKeys: String, CodingKey {
        case title
        case detail
        case priority
        case metric
        case tone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.decodeFlexibleStringIfPresent(forKey: .title) ?? "Adjust effort"
        detail = container.decodeFlexibleStringIfPresent(forKey: .detail) ?? "Keep the next run controlled and easy."
        priority = container.decodeFlexibleStringIfPresent(forKey: .priority) ?? "Medium"
        metric = container.decodeFlexibleStringIfPresent(forKey: .metric)
        tone = container.decodeFlexibleStringIfPresent(forKey: .tone)
    }
}

struct AICoachStructuredResponse: Decodable, Sendable {
    struct NextWorkout: Decodable, Sendable {
        let title: String
        let rationale: String

        init(title: String, rationale: String) {
            self.title = title
            self.rationale = rationale
        }

        enum CodingKeys: String, CodingKey {
            case title
            case rationale
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = container.decodeFlexibleStringIfPresent(forKey: .title) ?? "Next easy run"
            rationale = container.decodeFlexibleStringIfPresent(forKey: .rationale) ?? "Keep the next session controlled so the training plan stays on track."
        }
    }

    let headline: String
    let summary: String
    let fullAnalysis: String?
    let confidence: Int
    let evidence: [AICoachEvidenceItem]
    let actionItems: [AICoachActionItem]
    let nextWorkout: NextWorkout

    enum CodingKeys: String, CodingKey {
        case headline
        case summary
        case fullAnalysis = "full_analysis"
        case confidence
        case evidence
        case actionItems = "action_items"
        case actions
        case nextWorkout = "next_workout"
    }

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headline = container.decodeFlexibleStringIfPresent(forKey: .headline) ?? "Workout analysis"
        summary = container.decodeFlexibleStringIfPresent(forKey: .summary)
            ?? container.decodeFlexibleStringIfPresent(forKey: .fullAnalysis)
            ?? ""
        fullAnalysis = container.decodeFlexibleStringIfPresent(forKey: .fullAnalysis)
        confidence = container.decodeFlexibleIntIfPresent(forKey: .confidence) ?? 0
        evidence = (try? container.decodeIfPresent([AICoachEvidenceItem].self, forKey: .evidence)) ?? []
        actionItems = (try? container.decodeIfPresent([AICoachActionItem].self, forKey: .actionItems))
            ?? (try? container.decodeIfPresent([AICoachActionItem].self, forKey: .actions))
            ?? []
        nextWorkout = (try? container.decodeIfPresent(NextWorkout.self, forKey: .nextWorkout))
            ?? NextWorkout(title: "Next easy run", rationale: "Keep the next session controlled so the training plan stays on track.")
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let digits = value.filter { $0.isNumber }
            return Int(digits)
        }
        return nil
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

    func chatWithProvider(
        provider: AIProvider,
        context: String,
        messages: [AIProviderChatMessage]
    ) async throws -> String {
        guard let backend = onDeviceBackend, await backend.isAvailable() else {
            throw OnDeviceCoachError.unavailable
        }
        return try await backend.generateChatReply(
            instructions: Self.chatInstructions,
            context: context,
            messages: messages,
            useServerModel: provider.usesPrivateCloudCompute
        )
    }

    @MainActor
    func evaluateWithProvider(
        workout: RunWorkout,
        recentHistory: [RunWorkout],
        profile: UserProfile?,
        provider: AIProvider,
        unitPreference: UnitPreference = .metric,
        onChunk: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> AICoachInsight {
        let context = makePromptContext(
            workout: workout,
            recentHistory: recentHistory,
            profile: profile,
            unitPreference: unitPreference
        )
        let details = makeWorkoutDetails(
            workout: workout,
            recentHistory: recentHistory,
            profile: profile,
            unitPreference: unitPreference
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
                    onPartial: onChunk
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
            evidence: Array(structured.evidence.prefix(4)),
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
        unitPreference: UnitPreference = .metric
    ) async -> ScheduledWorkout? {
        guard scheduled.workoutType != .rest,
              scheduled.workoutType != .crossTraining else {
            return scheduled
        }

        let adaptationContext = makeAdaptationContext(
            scheduled: scheduled,
            recentHistory: recentHistory,
            profile: profile,
            unitPreference: unitPreference
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
        onChunk: @escaping @Sendable (String) -> Void = { _ in }
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
            onPartial: onChunk
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
        adapted.week = scheduled.week
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
            let totalDuration = (totalDistance / 1_000 * pace) + (Double(repetitions) * recoverySeconds)
            return WorkoutStructure(
                warmup: WorkoutSegment(distanceMeters: warmupDistance, durationSeconds: nil, targetPaceSecondsPerKm: easyPace, label: "Warm-up"),
                mainSets: [
                    WorkoutSet(
                        repetitions: repetitions,
                        workSegment: WorkoutSegment(distanceMeters: workDistance, durationSeconds: nil, targetPaceSecondsPerKm: interval?.targetPaceSecondsPerKm ?? pace, label: "Interval"),
                        recoverySegment: WorkoutSegment(distanceMeters: nil, durationSeconds: recoverySeconds, targetPaceSecondsPerKm: nil, label: "Recovery jog"),
                        label: "Interval Set"
                    )
                ],
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

        if let averageRecentPace {
            let delta = workout.averagePaceSecondsPerKm - averageRecentPace
            if delta < -8 {
                summaryBits.append("This run was faster than your recent quality baseline.")
            } else if delta > 8 {
                focus.append("Prioritize recovery before the next quality day.")
                summaryBits.append("This run was slower than your recent quality baseline.")
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
        unitPreference: UnitPreference
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

        let recent = recentHistory.prefix(8).map { run in
            let avgHR = run.averageHeartRate.map { "\(Int($0)) bpm" } ?? "n/a"
            return "\(run.date.formatted(date: .abbreviated, time: .omitted)) | \(run.workoutType.displayName) | \(run.distanceMeters.distanceString(unit: unitPreference)) | avg pace \(run.averagePaceSecondsPerKm.paceString(unit: unitPreference)) | duration \(run.durationSeconds.durationString) | avg HR \(avgHR)"
        }.joined(separator: "\n")

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
        let recent = recentHistory.prefix(8).map { run in
            let avgHR = run.averageHeartRate.map { "\(Int($0)) bpm" } ?? "n/a"
            return "\(run.date.formatted(date: .abbreviated, time: .omitted)) | \(run.workoutType.displayName) | \(run.distanceMeters.distanceString(unit: unitPreference)) | pace \(run.averagePaceSecondsPerKm.paceString(unit: unitPreference)) | \(run.durationSeconds.durationString) | HR \(avgHR)"
        }.joined(separator: "\n")
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

        Scheduled workouts:
        \(workoutRows)
        """
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
        unitPreference: UnitPreference
    ) -> String {
        let date = workout.date.formatted(date: .abbreviated, time: .shortened)
        let avgPace = workout.averagePaceSecondsPerKm.paceString(unit: unitPreference)
        let avgHR = workout.averageHeartRate.map { "\(Int($0)) bpm" } ?? "n/a"
        let maxHR = workout.maxHeartRate.map { "\(Int($0)) bpm" } ?? "n/a"
        let elevation = workout.elevationGainMeters.map { $0.elevationString(unit: unitPreference) } ?? "n/a"
        let weather = workout.weather.map {
            "\($0.conditionDescription), \($0.temperatureString(unit: unitPreference)), humidity \(Int($0.humidityPercent))%"
        } ?? "n/a"
        let profileContext = profile.map {
            "Goal race: \(raceLabel(race: $0.goalRace, distanceMeters: $0.effectiveRaceDistanceMeters, unitPreference: unitPreference)), fitness level: \($0.fitnessLevel.displayName), run days/week: \($0.weeklyRunDays)"
        } ?? "No athlete profile available."

        let splits = workout.splits.prefix(10).map {
            "\(splitDistanceLabel(split: $0, unitPreference: unitPreference)): pace \($0.paceSecondsPerKm.paceString(unit: unitPreference)), hr \($0.heartRate.map { String(Int($0)) } ?? "n/a"), elev \($0.elevationGainMeters.elevationString(unit: unitPreference))"
        }.joined(separator: "\n")
        let splitSection = splits.isEmpty ? "No split data." : splits

        let recent = recentHistory.prefix(5).map { run in
            "\(run.date.formatted(date: .abbreviated, time: .omitted)) • \(run.workoutType.displayName) • \(run.distanceMeters.distanceString(unit: unitPreference)) • \(run.averagePaceSecondsPerKm.paceString(unit: unitPreference))"
        }.joined(separator: "\n")
        let recentSection = recent.isEmpty ? "No recent runs." : recent

        return """
        Date: \(date)
        Type: \(workout.workoutType.displayName)
        Distance: \(workout.distanceMeters.distanceString(unit: unitPreference))
        Duration: \(workout.durationSeconds.durationString)
        Avg pace: \(avgPace)
        Avg HR: \(avgHR)
        Max HR: \(maxHR)
        Elevation gain: \(elevation)
        Weather: \(weather)
        \(profileContext)

        Splits:
        \(splitSection)

        Recent history:
        \(recentSection)
        """
    }

    private func splitDistanceLabel(split: Split, unitPreference: UnitPreference) -> String {
        if split.cumulativeDistanceMeters > 0 {
            return split.cumulativeDistanceMeters.distanceString(unit: unitPreference)
        }

        let distanceMeters = Double(split.kilometer) * 1_000
        return distanceMeters.distanceString(unit: unitPreference)
    }
}

// MARK: - On-device prompt + instruction builders
//
// Instructions carry the coaching guidance; the structural rules (counts, ranges,
// field lengths, enum choices) live in the `@Generable` `@Guide` annotations, so these
// strings omit the JSON-schema block the cloud prompts need.
extension AICoachService {
    static let chatInstructions = """
    You are Stride's AI running coach. Give concise, practical coaching answers grounded only in the supplied runner context and conversation. Avoid medical advice or clinical claims, do not claim certainty, and ask for more information when the data is insufficient. Keep answers under 120 words unless the runner asks for detail.
    """

    static let insightInstructions = """
    You are an expert running coach analysing a single completed run. Give concise, practical, evidence-based feedback grounded only in the supplied data. Cite this run's actual pace, splits, distance, terrain, and conditions, and tailor the read to what is distinctive about this session rather than generic advice. Vary the lead focus run to run (pacing execution, split trends, structure, terrain, conditions, or recovery load). Treat heart rate as supporting context, not a problem, unless it is clearly and substantially abnormal for this run type. Avoid medical advice or clinical claims and never mention that you are an AI.
    """

    static func insightPrompt(summary: String, focusAreas: [String], details: String) -> String {
        let bullets = focusAreas.map { "- \($0)" }.joined(separator: "\n")
        return """
        Analyse this run and produce coaching feedback.

        Workout summary:
        \(summary)

        Workout details:
        \(details)

        Focus areas:
        \(bullets)
        """
    }

    static let adaptationInstructions = """
    You are an expert running coach adapting a single scheduled run using only the supplied athlete context. Keep the workout on its scheduled day and weekday. If the scheduled workout is a long run, keep it a long run; never convert a non-long-run into a long run. Tailor volume and intensity to the target race and current training phase. Express all paces in seconds per kilometre regardless of display unit. If the run should not change, return the same targets with an explanation. Avoid medical advice or clinical claims and never mention that you are an AI.
    """

    static func adaptationPrompt(context: String) -> String {
        """
        Adapt the scheduled run using only the athlete and workout context below.

        \(context)
        """
    }

    static let planAdaptationInstructions = """
    You are an expert running coach adapting several scheduled runs as one coordinated plan update, using only the supplied athlete context. Return exactly one adaptation per provided workout id, copying each id exactly. Keep each workout on its scheduled day and weekday. If a scheduled workout is a long run, keep it a long run; never convert a non-long-run into a long run. Tailor volume and intensity to the target race and training phase. Express all paces in seconds per kilometre. Keep explanations under 120 characters. Avoid medical advice or clinical claims and never mention that you are an AI.
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
