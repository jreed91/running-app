import Foundation

/// Abstraction over Apple's generative models so `AICoachService` can stay free of any
/// `FoundationModels` import and remain testable with a fake backend.
///
/// Implementations produce the *same* structured value types the cloud path parses
/// out of JSON (`AICoachStructuredResponse`, `AIWorkoutAdaptationResponse`, …), so all
/// of `AICoachService`'s downstream mapping and validation is reused unchanged. The
/// only thing that differs between the on-device and Private Cloud Compute models is
/// which model backs the session; the prompts, the `@Generable` schemas and every
/// downstream mapping are identical (Apple ships one unified API for both).
protocol OnDeviceCoachGenerating: Sendable {

    /// Whether a model is currently usable (eligible device, Apple Intelligence enabled,
    /// model downloaded and ready). True when *either* the on-device or the Private Cloud
    /// Compute model can serve a request.
    func isAvailable() async -> Bool

    /// A short, user-facing reason no model is available, or `nil` when one is.
    func unavailableReason() async -> String?

    /// Availability and daily-quota state of the Private Cloud Compute model, or `nil`
    /// when this build/OS has no server model at all.
    ///
    /// Apple asks apps not to surface quota as a dismissible alert but as visible status,
    /// so Settings renders this rather than waiting for a request to fail.
    func serverModelStatus() async -> ServerModelStatus?

    /// Presents the system flow that lets the runner raise their daily PCC allowance
    /// (an iCloud+ upgrade). Only meaningful when
    /// `ServerModelStatus.canRequestLimitIncrease` is true.
    @MainActor
    func presentLimitIncrease()

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

extension OnDeviceCoachGenerating {
    /// Backends without a server model (older OSes, test fakes) report no status, which
    /// the UI reads as "nothing to say about Private Cloud Compute".
    func serverModelStatus() async -> ServerModelStatus? { nil }

    @MainActor
    func presentLimitIncrease() {}
}

// MARK: - Server model status

/// A snapshot of the Private Cloud Compute model's availability and daily quota, in
/// plain value types so views and `AICoachService` never import `FoundationModels`.
struct ServerModelStatus: Sendable, Equatable {

    /// Mirrors `PrivateCloudComputeLanguageModel.Availability`. PCC only runs on devices
    /// that support Apple Intelligence, and `systemNotReady` additionally covers the
    /// entitlement not being granted to the signing account.
    enum Availability: Sendable, Equatable {
        case available
        case deviceNotEligible
        case systemNotReady
        case unknownReason
    }

    /// Mirrors `PrivateCloudComputeLanguageModel.QuotaUsage.Status`. The daily allowance
    /// is Apple's, not the app's — there is no token cost to the developer.
    enum Quota: Sendable, Equatable {
        case belowLimit(approachingLimit: Bool)
        case limitReached
    }

    var availability: Availability
    var quota: Quota
    /// When the daily allowance refreshes. `nil` when unknown, or when the runner is well
    /// below their limit.
    var resetDate: Date?
    /// Whether the system offers an upgrade path worth surfacing a button for.
    var canRequestLimitIncrease: Bool
    /// The model's context window in tokens (32K for PCC vs. 8K on-device) — used by the
    /// Settings footnote so the number never drifts from the SDK.
    var contextSize: Int

    var isAvailable: Bool { availability == .available }

    var isLimitReached: Bool { quota == .limitReached }

    var isApproachingLimit: Bool {
        if case .belowLimit(let approaching) = quota { return approaching }
        return false
    }

    /// A short status line, or `nil` when there is nothing a runner needs to know.
    var quotaMessage: String? {
        switch quota {
        case .limitReached:
            return String(
                localized: "Daily Private Cloud Compute limit reached",
                comment: "AI coach quota status"
            )
        case .belowLimit(let approaching):
            guard approaching else { return nil }
            return String(
                localized: "Nearing today's Private Cloud Compute limit",
                comment: "AI coach quota status"
            )
        }
    }
}

enum OnDeviceCoachError: Error {
    case unavailable
    case emptyResponse
    case malformedResponse
    /// The runner used up their daily Private Cloud Compute allowance. Carries the refresh
    /// date when the framework knows it. Deliberately *not* folded into `unavailable`:
    /// the on-device model is still there, but the runner asked for the server model and
    /// should be told why they did not get it.
    case serverQuotaExceeded(resetDate: Date?)
}

/// Builds the default backend when the framework is present, otherwise `nil`.
/// `AICoachService` treats `nil` as "Apple Intelligence unsupported" and falls back.
enum OnDeviceCoachFactory {
    static func makeDefault() -> (any OnDeviceCoachGenerating)? {
        #if canImport(FoundationModels)
        return FoundationModelsCoachBackend()
        #else
        return nil
        #endif
    }
}
