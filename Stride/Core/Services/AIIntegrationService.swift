import Foundation

protocol AIIntegrationServiceProtocol: Sendable {
    func generateCoachingNarrative(
        provider: AIProvider,
        apiKey: String,
        model: String,
        workoutSummary: String,
        focusAreas: [String],
        workoutDetails: String
    ) async throws -> String

    func generateWorkoutAdaptation(
        provider: AIProvider,
        apiKey: String,
        model: String,
        adaptationContext: String
    ) async throws -> String
}

enum AIIntegrationError: Error {
    case invalidResponse
    case emptyMessage
}

struct AIIntegrationService: AIIntegrationServiceProtocol, Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generateCoachingNarrative(
        provider: AIProvider,
        apiKey: String,
        model: String,
        workoutSummary: String,
        focusAreas: [String],
        workoutDetails: String
    ) async throws -> String {
        switch provider {
        case .openAI:
            return try await requestOpenAI(
                apiKey: apiKey,
                model: model,
                workoutSummary: workoutSummary,
                focusAreas: focusAreas,
                workoutDetails: workoutDetails
            )
        case .anthropic:
            return try await requestAnthropic(
                apiKey: apiKey,
                model: model,
                workoutSummary: workoutSummary,
                focusAreas: focusAreas,
                workoutDetails: workoutDetails
            )
        }
    }

    func generateWorkoutAdaptation(
        provider: AIProvider,
        apiKey: String,
        model: String,
        adaptationContext: String
    ) async throws -> String {
        switch provider {
        case .openAI:
            return try await requestOpenAIAdaptation(
                apiKey: apiKey,
                model: model,
                adaptationContext: adaptationContext
            )
        case .anthropic:
            return try await requestAnthropicAdaptation(
                apiKey: apiKey,
                model: model,
                adaptationContext: adaptationContext
            )
        }
    }

    private func requestOpenAI(
        apiKey: String,
        model: String,
        workoutSummary: String,
        focusAreas: [String],
        workoutDetails: String
    ) async throws -> String {
        let prompt = makePrompt(workoutSummary: workoutSummary, focusAreas: focusAreas, workoutDetails: workoutDetails)
        let body = OpenAIRequest(
            model: model,
            messages: [
                .init(role: "system", content: "You are a running coach. Return only valid JSON that matches the requested schema."),
                .init(role: "user", content: prompt)
            ],
            temperature: 0.3,
            responseFormat: .init(type: "json_object")
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIIntegrationError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let message = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            throw AIIntegrationError.emptyMessage
        }
        return message
    }

    private func requestAnthropic(
        apiKey: String,
        model: String,
        workoutSummary: String,
        focusAreas: [String],
        workoutDetails: String
    ) async throws -> String {
        let prompt = makePrompt(workoutSummary: workoutSummary, focusAreas: focusAreas, workoutDetails: workoutDetails)
        let body = AnthropicRequest(
            model: model,
            maxTokens: 700,
            messages: [.init(role: "user", content: prompt)]
        )

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIIntegrationError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        let text = decoded.content
            .filter { $0.type == "text" }
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIIntegrationError.emptyMessage }
        return text
    }

    private func requestOpenAIAdaptation(
        apiKey: String,
        model: String,
        adaptationContext: String
    ) async throws -> String {
        let body = OpenAIRequest(
            model: model,
            messages: [
                .init(role: "system", content: "You are a running coach. Return only valid JSON that matches the requested schema."),
                .init(role: "user", content: makeAdaptationPrompt(adaptationContext: adaptationContext))
            ],
            temperature: 0.2,
            responseFormat: .init(type: "json_object")
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIIntegrationError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let message = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            throw AIIntegrationError.emptyMessage
        }
        return message
    }

    private func requestAnthropicAdaptation(
        apiKey: String,
        model: String,
        adaptationContext: String
    ) async throws -> String {
        let body = AnthropicRequest(
            model: model,
            maxTokens: 1_000,
            messages: [.init(role: "user", content: makeAdaptationPrompt(adaptationContext: adaptationContext))]
        )

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIIntegrationError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        let text = decoded.content
            .filter { $0.type == "text" }
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIIntegrationError.emptyMessage }
        return text
    }

    private func makePrompt(workoutSummary: String, focusAreas: [String], workoutDetails: String) -> String {
        let bullets = focusAreas.map { "- \($0)" }.joined(separator: "\n")
        return """
        Analyze this run and provide concise, practical coaching.

        Workout summary:
        \(workoutSummary)

        Workout details:
        \(workoutDetails)

        Focus areas:
        \(bullets)

        Return only valid JSON. Do not include markdown, prose before the JSON, code fences, or extra keys.
        Use this exact schema:
        {
          "headline": "Short coaching headline, maximum 8 words",
          "summary": "One plain-language sentence explaining the main takeaway",
          "action_items": [
            {
              "title": "Specific action, maximum 6 words",
              "detail": "One sentence explaining what to do and why",
              "priority": "High|Medium|Low"
            }
          ],
          "next_workout": {
            "title": "Specific next workout recommendation",
            "rationale": "One sentence explaining why this should come next"
          }
        }

        Rules:
        - Include exactly 3 action_items.
        - Make every action concrete enough to do in the next 7 days.
        - Avoid medical diagnosis and avoid mentioning that you are an AI.
        - Keep all values as strings.
        """
    }

    private func makeAdaptationPrompt(adaptationContext: String) -> String {
        """
        Adapt the scheduled run using only the athlete context below. The adaptation decision and the explanation must come from your coaching judgment.

        Athlete and workout context:
        \(adaptationContext)

        Return only valid JSON. Do not include markdown, prose before the JSON, code fences, or extra keys.
        Use this exact schema:
        {
          "workout_type": "Easy|Tempo|Interval|Long Run",
          "target_distance_meters": 5000,
          "target_pace_lower_bound": 330,
          "target_pace_upper_bound": 360,
          "explanation": "One concise paragraph explaining why this adaptation is appropriate.",
          "intervals": [
            {
              "repetitions": 4,
              "distance_meters": 800,
              "duration_seconds": null,
              "target_pace_seconds_per_km": 300,
              "recovery_seconds": 90,
              "recovery_type": "jog"
            }
          ],
          "workout_structure": {
            "warmup": {
              "distance_meters": 1000,
              "duration_seconds": null,
              "target_pace_seconds_per_km": 390,
              "label": "Warm-up"
            },
            "main_sets": [
              {
                "repetitions": 1,
                "work_segment": {
                  "distance_meters": 3000,
                  "duration_seconds": null,
                  "target_pace_seconds_per_km": 330,
                  "label": "Tempo"
                },
                "recovery_segment": {
                  "distance_meters": null,
                  "duration_seconds": null,
                  "target_pace_seconds_per_km": null,
                  "label": ""
                },
                "label": "Tempo Block"
              }
            ],
            "cooldown": {
              "distance_meters": 1000,
              "duration_seconds": null,
              "target_pace_seconds_per_km": 390,
              "label": "Cool-down"
            },
            "total_estimated_distance_meters": 5000,
            "total_estimated_duration_seconds": 1800
          }
        }

        Rules:
        - Choose workout_type from Easy, Tempo, Interval, or Long Run.
        - Use seconds per kilometer for all pace values, regardless of display unit.
        - Keep target_distance_meters between 500 and 50000.
        - Keep pace values between 120 and 900 seconds per kilometer.
        - Include an empty intervals array unless workout_type is Interval.
        - Include workout_structure for every adapted run.
        - Avoid medical diagnosis and avoid mentioning that you are an AI.
        - If the original workout should not change, return the same workout targets with an explanation.
        """
    }
}

private struct OpenAIRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case responseFormat = "response_format"
    }
}

private struct OpenAIResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct AnthropicRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let maxTokens: Int
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
    }
}

private struct AnthropicResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String
    }

    let content: [ContentBlock]
}
