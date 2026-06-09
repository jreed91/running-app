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

    func generateCoachingNarrativeStreaming(
        provider: AIProvider,
        apiKey: String,
        model: String,
        workoutSummary: String,
        focusAreas: [String],
        workoutDetails: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String

    func generateWorkoutAdaptation(
        provider: AIProvider,
        apiKey: String,
        model: String,
        adaptationContext: String
    ) async throws -> String

    func generateWorkoutPlanAdaptation(
        provider: AIProvider,
        apiKey: String,
        model: String,
        adaptationContext: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String

    func generateCoachChatReply(
        provider: AIProvider,
        apiKey: String,
        model: String,
        context: String,
        messages: [AIProviderChatMessage]
    ) async throws -> String
}

enum AIIntegrationError: Error {
    case invalidResponse
    case emptyMessage
}

struct AIProviderChatMessage: Sendable {
    let role: String
    let content: String
}

struct AIIntegrationService: AIIntegrationServiceProtocol, Sendable {
    private static let coachingMaxTokens = 2_000

    private let session: any StrideURLSessionProtocol

    init(session: any StrideURLSessionProtocol = PulseIntegrationService.makeURLSession()) {
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
        default:
            // Apple on-device / Private Cloud Compute providers are handled in AICoachService.
            throw AIIntegrationError.invalidResponse
        }
    }

    func generateCoachingNarrativeStreaming(
        provider: AIProvider,
        apiKey: String,
        model: String,
        workoutSummary: String,
        focusAreas: [String],
        workoutDetails: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        switch provider {
        case .openAI:
            return try await requestOpenAICoachingNarrativeStream(
                apiKey: apiKey,
                model: model,
                workoutSummary: workoutSummary,
                focusAreas: focusAreas,
                workoutDetails: workoutDetails,
                onChunk: onChunk
            )
        case .anthropic:
            return try await requestAnthropicCoachingNarrativeStream(
                apiKey: apiKey,
                model: model,
                workoutSummary: workoutSummary,
                focusAreas: focusAreas,
                workoutDetails: workoutDetails,
                onChunk: onChunk
            )
        default:
            throw AIIntegrationError.invalidResponse
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
        default:
            throw AIIntegrationError.invalidResponse
        }
    }

    func generateWorkoutPlanAdaptation(
        provider: AIProvider,
        apiKey: String,
        model: String,
        adaptationContext: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        switch provider {
        case .openAI:
            return try await requestOpenAIPlanAdaptation(
                apiKey: apiKey,
                model: model,
                adaptationContext: adaptationContext,
                onChunk: onChunk
            )
        case .anthropic:
            return try await requestAnthropicPlanAdaptation(
                apiKey: apiKey,
                model: model,
                adaptationContext: adaptationContext,
                onChunk: onChunk
            )
        default:
            throw AIIntegrationError.invalidResponse
        }
    }

    func generateCoachChatReply(
        provider: AIProvider,
        apiKey: String,
        model: String,
        context: String,
        messages: [AIProviderChatMessage]
    ) async throws -> String {
        switch provider {
        case .openAI:
            return try await requestOpenAIChat(
                apiKey: apiKey,
                model: model,
                context: context,
                messages: messages
            )
        case .anthropic:
            return try await requestAnthropicChat(
                apiKey: apiKey,
                model: model,
                context: context,
                messages: messages
            )
        default:
            throw AIIntegrationError.invalidResponse
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
            responseFormat: .init(type: "json_object"),
            maxTokens: Self.coachingMaxTokens
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
            maxTokens: Self.coachingMaxTokens,
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

    private func requestOpenAIChat(
        apiKey: String,
        model: String,
        context: String,
        messages: [AIProviderChatMessage]
    ) async throws -> String {
        let promptMessages = [
            OpenAIRequest.Message(
                role: "system",
                content: """
                You are Stride's AI running coach. Give concise, practical coaching answers grounded only in the supplied runner context and conversation. Avoid medical advice or clinical claims, do not claim certainty, and ask for more information when the data is insufficient. Keep answers under 120 words unless the runner asks for detail.
                """
            ),
            OpenAIRequest.Message(role: "user", content: "Runner context:\n\(context)")
        ] + messages.map {
            OpenAIRequest.Message(role: $0.role == "assistant" ? "assistant" : "user", content: $0.content)
        }

        let body = OpenAIRequest(
            model: model,
            messages: promptMessages,
            temperature: 0.4,
            responseFormat: nil,
            maxTokens: 500
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

    private func requestAnthropicChat(
        apiKey: String,
        model: String,
        context: String,
        messages: [AIProviderChatMessage]
    ) async throws -> String {
        let prompt = """
        You are Stride's AI running coach. Give concise, practical coaching answers grounded only in the supplied runner context and conversation. Avoid medical advice or clinical claims, do not claim certainty, and ask for more information when the data is insufficient. Keep answers under 120 words unless the runner asks for detail.

        Runner context:
        \(context)
        """

        let body = AnthropicRequest(
            model: model,
            maxTokens: 500,
            system: prompt,
            messages: messages.map {
                AnthropicRequest.Message(role: $0.role == "assistant" ? "assistant" : "user", content: $0.content)
            }
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

    private func requestOpenAICoachingNarrativeStream(
        apiKey: String,
        model: String,
        workoutSummary: String,
        focusAreas: [String],
        workoutDetails: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let prompt = makePrompt(workoutSummary: workoutSummary, focusAreas: focusAreas, workoutDetails: workoutDetails)
        let body = OpenAIRequest(
            model: model,
            messages: [
                .init(role: "system", content: "You are a running coach. Return only valid JSON that matches the requested schema."),
                .init(role: "user", content: prompt)
            ],
            temperature: 0.3,
            responseFormat: .init(type: "json_object"),
            maxTokens: Self.coachingMaxTokens,
            stream: true
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        var message = ""
        var responseData = Data()
        var response: URLResponse?
        var didStorePulseRequest = false

        do {
            let (bytes, urlResponse) = try await session.bytes(for: request, delegate: nil)
            response = urlResponse
            guard let http = urlResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                didStorePulseRequest = true
                PulseIntegrationService.storeCompletedNetworkRequest(
                    request,
                    response: urlResponse,
                    error: AIIntegrationError.invalidResponse,
                    data: responseData,
                    label: "AI",
                    taskDescription: "OpenAI coaching narrative stream"
                )
                throw AIIntegrationError.invalidResponse
            }

            for try await line in bytes.lines {
                responseData.append(Data((line + "\n").utf8))
                guard line.hasPrefix("data:") else { continue }
                let payload = line
                    .dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
                      let text = chunk.choices.first?.delta.content,
                      !text.isEmpty else {
                    continue
                }
                message += text
                onChunk(text)
            }

            PulseIntegrationService.storeCompletedNetworkRequest(
                request,
                response: urlResponse,
                error: nil,
                data: responseData,
                label: "AI",
                taskDescription: "OpenAI coaching narrative stream"
            )
            didStorePulseRequest = true
        } catch {
            if !didStorePulseRequest {
                PulseIntegrationService.storeCompletedNetworkRequest(
                    request,
                    response: response,
                    error: error,
                    data: responseData,
                    label: "AI",
                    taskDescription: "OpenAI coaching narrative stream"
                )
            }
            throw error
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIIntegrationError.emptyMessage }
        return trimmed
    }

    private func requestAnthropicCoachingNarrativeStream(
        apiKey: String,
        model: String,
        workoutSummary: String,
        focusAreas: [String],
        workoutDetails: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let prompt = makePrompt(workoutSummary: workoutSummary, focusAreas: focusAreas, workoutDetails: workoutDetails)
        let body = AnthropicRequest(
            model: model,
            maxTokens: Self.coachingMaxTokens,
            messages: [.init(role: "user", content: prompt)],
            stream: true
        )

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        var message = ""
        var responseData = Data()
        var response: URLResponse?
        var didStorePulseRequest = false

        do {
            let (bytes, urlResponse) = try await session.bytes(for: request, delegate: nil)
            response = urlResponse
            guard let http = urlResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                didStorePulseRequest = true
                PulseIntegrationService.storeCompletedNetworkRequest(
                    request,
                    response: urlResponse,
                    error: AIIntegrationError.invalidResponse,
                    data: responseData,
                    label: "AI",
                    taskDescription: "Anthropic coaching narrative stream"
                )
                throw AIIntegrationError.invalidResponse
            }

            for try await line in bytes.lines {
                responseData.append(Data((line + "\n").utf8))
                guard line.hasPrefix("data:") else { continue }
                let payload = line
                    .dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data),
                      let text = event.delta?.text,
                      !text.isEmpty else {
                    continue
                }
                message += text
                onChunk(text)
            }

            PulseIntegrationService.storeCompletedNetworkRequest(
                request,
                response: urlResponse,
                error: nil,
                data: responseData,
                label: "AI",
                taskDescription: "Anthropic coaching narrative stream"
            )
            didStorePulseRequest = true
        } catch {
            if !didStorePulseRequest {
                PulseIntegrationService.storeCompletedNetworkRequest(
                    request,
                    response: response,
                    error: error,
                    data: responseData,
                    label: "AI",
                    taskDescription: "Anthropic coaching narrative stream"
                )
            }
            throw error
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIIntegrationError.emptyMessage }
        return trimmed
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

    private func requestOpenAIPlanAdaptation(
        apiKey: String,
        model: String,
        adaptationContext: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let body = OpenAIRequest(
            model: model,
            messages: [
                .init(role: "system", content: "You are a running coach. Return only valid JSON that matches the requested schema."),
                .init(role: "user", content: makePlanAdaptationPrompt(adaptationContext: adaptationContext))
            ],
            temperature: 0.2,
            responseFormat: .init(type: "json_object"),
            stream: true
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        var message = ""
        var responseData = Data()
        var response: URLResponse?
        var didStorePulseRequest = false

        do {
            let (bytes, urlResponse) = try await session.bytes(for: request, delegate: nil)
            response = urlResponse
            guard let http = urlResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                didStorePulseRequest = true
                PulseIntegrationService.storeCompletedNetworkRequest(
                    request,
                    response: urlResponse,
                    error: AIIntegrationError.invalidResponse,
                    data: responseData,
                    label: "AI",
                    taskDescription: "OpenAI plan adaptation stream"
                )
                throw AIIntegrationError.invalidResponse
            }

            for try await line in bytes.lines {
                responseData.append(Data((line + "\n").utf8))
                guard line.hasPrefix("data:") else { continue }
                let payload = line
                    .dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
                      let text = chunk.choices.first?.delta.content,
                      !text.isEmpty else {
                    continue
                }
                message += text
                onChunk(text)
            }

            PulseIntegrationService.storeCompletedNetworkRequest(
                request,
                response: urlResponse,
                error: nil,
                data: responseData,
                label: "AI",
                taskDescription: "OpenAI plan adaptation stream"
            )
            didStorePulseRequest = true
        } catch {
            if !didStorePulseRequest {
                PulseIntegrationService.storeCompletedNetworkRequest(
                    request,
                    response: response,
                    error: error,
                    data: responseData,
                    label: "AI",
                    taskDescription: "OpenAI plan adaptation stream"
                )
            }
            throw error
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIIntegrationError.emptyMessage
        }
        return trimmed
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

    private func requestAnthropicPlanAdaptation(
        apiKey: String,
        model: String,
        adaptationContext: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let body = AnthropicRequest(
            model: model,
            maxTokens: 3_000,
            messages: [.init(role: "user", content: makePlanAdaptationPrompt(adaptationContext: adaptationContext))],
            stream: true
        )

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        var message = ""
        var responseData = Data()
        var response: URLResponse?
        var didStorePulseRequest = false

        do {
            let (bytes, urlResponse) = try await session.bytes(for: request, delegate: nil)
            response = urlResponse
            guard let http = urlResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                didStorePulseRequest = true
                PulseIntegrationService.storeCompletedNetworkRequest(
                    request,
                    response: urlResponse,
                    error: AIIntegrationError.invalidResponse,
                    data: responseData,
                    label: "AI",
                    taskDescription: "Anthropic plan adaptation stream"
                )
                throw AIIntegrationError.invalidResponse
            }

            for try await line in bytes.lines {
                responseData.append(Data((line + "\n").utf8))
                guard line.hasPrefix("data:") else { continue }
                let payload = line
                    .dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data),
                      let text = event.delta?.text,
                      !text.isEmpty else {
                    continue
                }
                message += text
                onChunk(text)
            }

            PulseIntegrationService.storeCompletedNetworkRequest(
                request,
                response: urlResponse,
                error: nil,
                data: responseData,
                label: "AI",
                taskDescription: "Anthropic plan adaptation stream"
            )
            didStorePulseRequest = true
        } catch {
            if !didStorePulseRequest {
                PulseIntegrationService.storeCompletedNetworkRequest(
                    request,
                    response: response,
                    error: error,
                    data: responseData,
                    label: "AI",
                    taskDescription: "Anthropic plan adaptation stream"
                )
            }
            throw error
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIIntegrationError.emptyMessage }
        return trimmed
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
          "full_analysis": "A fuller 3-5 sentence coaching explanation with the why, the evidence, and how to adjust the next week.",
          "confidence": 82,
          "evidence": [
            {
              "label": "Pace",
              "value": "5:02/km",
              "delta": "+0:18",
              "tone": "warning"
            }
          ],
          "action_items": [
            {
              "title": "Specific action, maximum 6 words",
              "detail": "One sentence explaining what to do and why",
              "priority": "High|Medium|Low",
              "metric": "≤150 bpm",
              "tone": "easy|brand|interval|warning|neutral"
            }
          ],
          "next_workout": {
            "title": "Specific next workout recommendation",
            "rationale": "One sentence explaining why this should come next"
          }
        }

        Rules:
        - confidence must be an integer from 0 to 100.
        - full_analysis must be 2 to 3 concise sentences that explain the coaching read, key evidence, and practical adjustment.
        - Ground every observation in THIS run's specific data: cite its actual pace, splits, distance, terrain, and conditions, and tailor the headline, analysis, and actions to what is distinctive about this session. Do not reuse generic running advice or boilerplate that would fit any run.
        - Vary the focus from run to run: lead with whatever stands out most in this workout (pacing execution, split trends, workout structure, terrain, conditions, or recovery load) rather than defaulting to the same theme every time.
        - Prioritize analysis across pace execution, workout structure, distance, duration, splits, cadence/form clues, and recovery load; use heart-rate as supporting context only.
        - Be lenient with heart rate. Elevated or drifting heart rate is normal and expected on hard, long, hot, or hilly runs, so do NOT flag it as a problem unless it is clearly and substantially outside the normal range for this run type AND another signal corroborates it. When in doubt, treat heart rate as informational rather than a concern.
        - Include exactly 4 evidence items. Each evidence item should be a compact display chip: label maximum 10 characters, value maximum 12 characters, optional delta maximum 8 characters.
        - Include at most 1 heart-rate evidence item, and only make heart rate the headline or a high-priority action when the focus areas explicitly call it out.
        - Evidence tone must be one of: warning, success, brand, easy, interval, neutral.
        - Include exactly 3 action_items.
        - Each action item must include a compact metric badge, maximum 10 characters.
        - Action item tone must be one of: easy, brand, interval, warning, neutral.
        - Make every action concrete enough to do in the next 7 days.
        - Avoid medical advice or clinical claims and avoid mentioning that you are an AI.
        - Keep all values as strings except confidence.
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
        - Do not move workouts to different dates or weekdays.
        - Respect the runner's selected running days and the existing long-run day.
        - If the scheduled workout is a Long Run, keep it as Long Run.
        - Do not turn a non-long-run workout into a Long Run.
        - Tailor volume and intensity to the target race and current training phase.
        - Use seconds per kilometer for all pace values, regardless of display unit.
        - Keep target_distance_meters between 500 and 50000.
        - Keep pace values between 120 and 900 seconds per kilometer.
        - Include an empty intervals array unless workout_type is Interval.
        - Include workout_structure for every adapted run.
        - Avoid medical advice or clinical claims and avoid mentioning that you are an AI.
        - If the original workout should not change, return the same workout targets with an explanation.
        """
    }

    private func makePlanAdaptationPrompt(adaptationContext: String) -> String {
        """
        Adapt all scheduled runs in one pass using only the athlete context below. The adaptation decisions and explanations must come from your coaching judgment.

        Athlete, plan, and workout context:
        \(adaptationContext)

        Return only valid JSON. Do not include markdown, prose before the JSON, code fences, or extra keys.
        Use this exact schema:
        {
          "summary": ["Short user-facing plan change"],
          "adaptations": [
            {
              "workout_id": "UUID copied exactly from the workout context",
              "workout_type": "Easy|Tempo|Interval|Long Run",
              "target_distance_meters": 5000,
              "target_pace_lower_bound": 330,
              "target_pace_upper_bound": 360,
              "explanation": "One short sentence explaining the change.",
              "intervals": []
            }
          ]
        }

        Rules:
        - Put summary before adaptations.
        - Include 1 to 4 summary strings.
        - Make summary user-facing and specific, such as reduced volume, softened intensity, preserved long runs, or kept a workout unchanged.
        - Include exactly one adaptation for every workout_id in the context.
        - Copy each workout_id exactly.
        - Keep explanations under 120 characters.
        - Choose workout_type from Easy, Tempo, Interval, or Long Run.
        - Do not move workouts to different dates or weekdays.
        - Respect the runner's selected running days and the existing long-run day.
        - If the scheduled workout is a Long Run, keep it as Long Run.
        - Do not turn a non-long-run workout into a Long Run.
        - Tailor volume and intensity to the target race and current training phase.
        - Use seconds per kilometer for all pace values, regardless of display unit.
        - Keep target_distance_meters between 500 and 50000.
        - Keep pace values between 120 and 900 seconds per kilometer.
        - Include an empty intervals array unless workout_type is Interval.
        - Do not include workout_structure; Stride will derive it locally.
        - Avoid medical advice or clinical claims and avoid mentioning that you are an AI.
        - If an original workout should not change, return the same workout targets with an explanation.
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
    let responseFormat: ResponseFormat?
    var maxTokens: Int? = nil
    var stream: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
        case stream
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

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta
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
    var system: String? = nil
    let messages: [Message]
    var stream: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
    }
}

private struct AnthropicResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String
    }

    let content: [ContentBlock]
}

private struct AnthropicStreamEvent: Decodable {
    struct Delta: Decodable {
        let text: String?
    }

    let delta: Delta?
}
