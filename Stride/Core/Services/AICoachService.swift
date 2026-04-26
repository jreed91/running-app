import Foundation

struct AICoachInsight: Sendable {
    let headline: String
    let summary: String
    let actionItems: [AICoachActionItem]
    let focusAreas: [String]
    let nextWorkoutSuggestion: String
    let nextWorkoutRationale: String?
    let apiReady: Bool
}

struct AICoachActionItem: Codable, Hashable, Sendable {
    let title: String
    let detail: String
    let priority: String
}

struct AICoachStructuredResponse: Codable, Sendable {
    struct NextWorkout: Codable, Sendable {
        let title: String
        let rationale: String
    }

    let headline: String
    let summary: String
    let actionItems: [AICoachActionItem]
    let nextWorkout: NextWorkout

    enum CodingKeys: String, CodingKey {
        case headline
        case summary
        case actionItems = "action_items"
        case nextWorkout = "next_workout"
    }
}

struct AICoachService: Sendable {
    let integrationService: AIIntegrationServiceProtocol

    init(integrationService: AIIntegrationServiceProtocol = AIIntegrationService()) {
        self.integrationService = integrationService
    }

    @MainActor
    func evaluateWithProvider(
        workout: RunWorkout,
        recentHistory: [RunWorkout],
        profile: UserProfile?,
        provider: AIProvider,
        apiKey: String,
        modelOverride: String,
        unitPreference: UnitPreference = .metric
    ) async -> AICoachInsight {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return AICoachInsight(
                headline: "AI Key Required",
                summary: "Add an AI API key in Settings to load cloud coaching insights.",
                actionItems: [],
                focusAreas: [],
                nextWorkoutSuggestion: "Set your key, then reload insights.",
                nextWorkoutRationale: nil,
                apiReady: false
            )
        }

        let context = makePromptContext(
            workout: workout,
            recentHistory: recentHistory,
            profile: profile,
            unitPreference: unitPreference
        )

        let selectedModel = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? provider.defaultModel
            : modelOverride

        do {
            let narrative = try await integrationService.generateCoachingNarrative(
                provider: provider,
                apiKey: trimmedKey,
                model: selectedModel,
                workoutSummary: context.summary,
                focusAreas: context.focusAreas,
                workoutDetails: makeWorkoutDetails(
                    workout: workout,
                    recentHistory: recentHistory,
                    profile: profile,
                    unitPreference: unitPreference
                )
            )

            guard let structured = Self.parseStructuredResponse(narrative) else {
                return unavailableInsight(reason: "The AI response was not in the structured format Stride needs to display.")
            }

            return AICoachInsight(
                headline: structured.headline.isEmpty ? "\(provider.displayName) Analysis" : structured.headline,
                summary: structured.summary,
                actionItems: Array(structured.actionItems.prefix(3)),
                focusAreas: structured.actionItems.map(\.title),
                nextWorkoutSuggestion: structured.nextWorkout.title,
                nextWorkoutRationale: structured.nextWorkout.rationale,
                apiReady: true
            )
        } catch {
            return unavailableInsight(reason: "Stride could not load structured AI insights. Check your API key, model, and network connection, then try again.")
        }
    }

    static func parseStructuredResponse(_ text: String) -> AICoachStructuredResponse? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            trimmed,
            extractFencedJSON(from: trimmed),
            extractJSONObject(from: trimmed)
        ].compactMap(\.self)

        let decoder = JSONDecoder()
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let decoded = try? decoder.decode(AICoachStructuredResponse.self, from: data) else {
                continue
            }

            let hasRequiredContent = !decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !decoded.nextWorkout.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !decoded.actionItems.isEmpty
            if hasRequiredContent {
                return decoded
            }
        }

        return nil
    }

    private static func extractFencedJSON(from text: String) -> String? {
        guard let opening = text.range(of: "```") else { return nil }
        let afterOpening = text[opening.upperBound...]
        let contentStart = afterOpening.hasPrefix("json")
            ? afterOpening.dropFirst("json".count)
            : Substring(afterOpening)
        guard let closing = contentStart.range(of: "```") else { return nil }
        return String(contentStart[..<closing.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(text[start...end])
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
            if drift <= 3 {
                summaryBits.append("Great pacing control across the run.")
            } else if drift <= 7 {
                focus.append("Start 3–5 sec/\(unitPreference.distanceLabel) easier for the first 2 splits.")
                summaryBits.append("Moderate pace fade late in the workout.")
            } else {
                focus.append("Pace conservatively early and protect form in final third.")
                summaryBits.append("Large late-run fade suggests pacing or endurance mismatch.")
            }
        }

        if let hrDrift, hrDrift > 8 {
            focus.append("Add easy aerobic volume or extend recoveries between reps.")
            summaryBits.append("Heart-rate drift was elevated, indicating accumulating fatigue.")
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

        if focus.isEmpty {
            focus.append("Keep weekly consistency: 1 long run, 1 quality run, remaining easy.")
        }

        let raceContext = profile.map { "Goal: \($0.goalRace.displayName)." } ?? ""
        let summary = ([raceContext] + summaryBits)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return (summary: summary.isEmpty ? "No local summary available." : summary, focusAreas: Array(focus.prefix(3)))
    }

    private func unavailableInsight(reason: String) -> AICoachInsight {
        AICoachInsight(
            headline: "AI Insight Unavailable",
            summary: reason,
            actionItems: [],
            focusAreas: [],
            nextWorkoutSuggestion: "Try refreshing structured AI insights again.",
            nextWorkoutRationale: nil,
            apiReady: false
        )
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
            "Goal race: \($0.goalRace.displayName), fitness level: \($0.fitnessLevel.displayName), run days/week: \($0.weeklyRunDays)"
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
