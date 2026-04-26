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
                .init(role: "system", content: "You are a running coach. Keep advice practical and concise."),
                .init(role: "user", content: prompt)
            ],
            temperature: 0.3
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
            maxTokens: 350,
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

    private func makePrompt(workoutSummary: String, focusAreas: [String], workoutDetails: String) -> String {
        let bullets = focusAreas.map { "- \($0)" }.joined(separator: "\n")
        return """
        Analyze this run and provide concise coaching.

        Workout summary:
        \(workoutSummary)

        Workout details:
        \(workoutDetails)

        Focus areas:
        \(bullets)

        Return:
        1) One paragraph summary.
        2) 3 actionable suggestions.
        3) A recommendation for the next workout.
        """
    }
}

private struct OpenAIRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
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
