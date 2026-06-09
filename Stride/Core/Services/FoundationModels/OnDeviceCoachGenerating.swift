import Foundation

/// Abstraction over Apple's on-device generative model so `AICoachService` can stay
/// free of any `FoundationModels` import and remain testable with a fake backend.
///
/// Implementations produce the *same* structured value types the cloud path parses
/// out of JSON (`AICoachStructuredResponse`, `AIWorkoutAdaptationResponse`, …), so all
/// of `AICoachService`'s downstream mapping and validation is reused unchanged. The
/// only thing that differs between cloud and on-device is where the structured value
/// comes from: JSON parsing vs. Foundation Models guided generation (`@Generable`).
protocol OnDeviceCoachGenerating: Sendable {

    /// Whether the on-device model is currently usable (eligible device, Apple
    /// Intelligence enabled, model downloaded and ready).
    func isAvailable() async -> Bool

    /// A short, user-facing reason the model is unavailable, or `nil` when available.
    func unavailableReason() async -> String?

    func generateCoachInsight(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> AICoachStructuredResponse

    func generateWorkoutAdaptation(
        instructions: String,
        prompt: String,
        useServerModel: Bool
    ) async throws -> AIWorkoutAdaptationResponse

    func generatePlanAdaptation(
        instructions: String,
        prompt: String,
        useServerModel: Bool,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> AIWorkoutPlanAdaptationResponse

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        useServerModel: Bool
    ) async throws -> String
}

enum OnDeviceCoachError: Error {
    case unavailable
    case emptyResponse
    case malformedResponse
}

/// Builds the default on-device backend when the framework is present, otherwise `nil`.
/// `AICoachService` treats `nil` as "on-device unsupported" and falls back accordingly.
enum OnDeviceCoachFactory {
    static func makeDefault() -> (any OnDeviceCoachGenerating)? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationModelsCoachBackend()
        }
        #endif
        return nil
    }
}
