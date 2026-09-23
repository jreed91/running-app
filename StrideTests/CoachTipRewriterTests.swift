import Foundation
import Testing
@testable import Stride

/// Covers `CoachTipRewriter` — what the model's wording for the Coach Tips has to get
/// past before it is drawn — and `AICoachService.writeCoachTips(for:)`, which asks for it.
///
/// The number check is the one that matters: these cards carry computed fuelling amounts,
/// and a rewrite is only ever allowed to reword them, never to change them.
struct CoachTipRewriterTests {

    // MARK: Fixtures

    private let fuelCard = SmartCoachCard(
        kind: .longRunFuel,
        title: "Practise your fuelling",
        message: "Tomorrow's Long Run goes past the point where you have to eat on the move. "
            + "Take 65 g an hour from about forty-five minutes in, with 450 ml an hour of fluid.",
        glance: "65 g an hour from forty-five minutes in, with 450 ml an hour of fluid.",
        tone: .neutral,
        score: 0.6,
        derivation: "0.9 g/kg/h · 72 kg · ~1.9 h · 123 g total"
    )

    private let loadCard = SmartCoachCard(
        kind: .load,
        title: "Big week — hold it there",
        message: "You've covered 52.0 km in the last seven days, 26% up on the seven before.",
        glance: "Volume is up sharply. Hold it here for a week before adding more.",
        tone: .caution,
        score: 0.42
    )

    private let noPlanCard = SmartCoachCard(
        kind: .noPlan,
        title: "No plan yet",
        message: "Free runs still count. Build a plan in the Plan tab when you want the sessions chosen.",
        glance: "Free runs still count. Build a plan when you want the sessions chosen.",
        tone: .neutral,
        score: 0.7
    )

    private func fuelDraft(message: String) -> CoachTipDraft {
        CoachTipDraft(id: "longRunFuel", title: "Fuel on the move", message: message)
    }

    // MARK: Numbers

    @Test func numbersKeepSeparatorsInsideANumberOnly() {
        #expect(CoachTipRewriter.numbers(in: "Easy runs at 5:12 per km, 4% slower.") == ["5:12", "4"])
        #expect(CoachTipRewriter.numbers(in: "You covered 52.0 km. Then 26, then 3.") == ["52.0", "26", "3"])
        #expect(CoachTipRewriter.numbers(in: "Take 60–90 g, or 1,200 ml.") == ["60", "90", "1,200"])
        #expect(CoachTipRewriter.numbers(in: "Twenty to thirty minutes easy.").isEmpty)
    }

    // MARK: Validation

    @Test func acceptsARewriteThatKeepsEveryNumber() {
        let draft = fuelDraft(
            message: "  Your Long Run tomorrow is long enough to need food on the go. "
                + "From about forty-five minutes in, take 65 g an hour and drink 450 ml an hour.  "
        )
        let accepted = CoachTipRewriter.validated([draft], for: [fuelCard])
        #expect(accepted.count == 1)
        #expect(accepted.first?.kind == .longRunFuel)
        #expect(accepted.first?.title == "Fuel on the move")
        #expect(accepted.first?.message.hasPrefix("Your Long Run") == true)
        #expect(accepted.first?.source == CoachTipRewriter.source(of: fuelCard))
    }

    @Test func rejectsAChangedAmount() {
        let draft = fuelDraft(message: "Take 80 g an hour from forty-five minutes in, with 450 ml an hour.")
        #expect(CoachTipRewriter.validated([draft], for: [fuelCard]).isEmpty)
    }

    @Test func rejectsADroppedAmount() {
        let draft = fuelDraft(message: "Take 65 g an hour from forty-five minutes in, and drink to thirst.")
        #expect(CoachTipRewriter.validated([draft], for: [fuelCard]).isEmpty)
    }

    @Test func rejectsAnAddedNumber() {
        let draft = fuelDraft(message: "Take 65 g an hour from 45 minutes in, with 450 ml an hour of fluid.")
        #expect(CoachTipRewriter.validated([draft], for: [fuelCard]).isEmpty)
    }

    @Test func rejectsUnknownDuplicateBlankAndOverlongDrafts() {
        let good = CoachTipDraft(id: "noPlan", title: "Build a plan", message: "Free runs count. Build a plan when you're ready.")
        let drafts = [
            CoachTipDraft(id: "heat", title: "Stay cool", message: "Drink more."),
            good,
            CoachTipDraft(id: "noPlan", title: "Second go", message: "This one arrives too late."),
            CoachTipDraft(id: "load", title: "  ", message: "You've covered 52.0 km, 26% up."),
        ]
        let accepted = CoachTipRewriter.validated(drafts, for: [noPlanCard, loadCard])
        #expect(accepted.map(\.kind) == [.noPlan])
        #expect(accepted.first?.title == "Build a plan")

        let overlong = CoachTipDraft(
            id: "noPlan",
            title: "Build a plan",
            message: String(repeating: "a", count: CoachTipRewriter.maximumMessageLength + 1)
        )
        #expect(CoachTipRewriter.validated([overlong], for: [noPlanCard]).isEmpty)
    }

    @Test func numbersInTheTitleCount() {
        let card = SmartCoachCard(
            kind: .raceWeek,
            title: "Race week — 5 days out",
            message: "Hold your usual carbohydrate through the taper.",
            glance: "Hold your usual carbohydrate through the taper.",
            tone: .positive,
            score: 1
        )
        let kept = CoachTipDraft(id: "raceWeek", title: "5 days to go", message: "Keep eating as usual through the taper.")
        let lost = CoachTipDraft(id: "raceWeek", title: "Race week", message: "Keep eating as usual through the taper.")
        #expect(CoachTipRewriter.validated([kept], for: [card]).count == 1)
        #expect(CoachTipRewriter.validated([lost], for: [card]).isEmpty)
    }

    // MARK: Applying

    @Test func applyRewordsOnlyTitleAndMessage() {
        let wording = CoachTipWording(
            kind: .load,
            title: "Hold this week steady",
            message: "You ran 52.0 km this week, 26% more than last week.",
            source: CoachTipRewriter.source(of: loadCard)
        )
        let applied = CoachTipRewriter.apply([wording], to: [fuelCard, loadCard])

        #expect(applied[0] == fuelCard)
        #expect(applied[1].title == "Hold this week steady")
        #expect(applied[1].message == "You ran 52.0 km this week, 26% more than last week.")
        #expect(applied[1].kind == loadCard.kind)
        #expect(applied[1].glance == loadCard.glance)
        #expect(applied[1].tone == loadCard.tone)
        #expect(applied[1].score == loadCard.score)
        #expect(applied[1].derivation == loadCard.derivation)
        #expect(applied[1].expiresAt == loadCard.expiresAt)
    }

    @Test func applyIgnoresWordingWrittenForDifferentText() {
        let stale = CoachTipWording(
            kind: .load,
            title: "Hold this week steady",
            message: "You ran 48.0 km this week.",
            source: "Big week — hold it there\nYou've covered 48.0 km in the last seven days."
        )
        #expect(CoachTipRewriter.apply([stale], to: [loadCard]) == [loadCard])
        #expect(CoachTipRewriter.cardsNeedingWording([loadCard], existing: [stale]) == [loadCard])
    }

    @Test func mergingKeepsCurrentWordingAndDropsStale() {
        let loadWording = CoachTipWording(
            kind: .load, title: "Old load", message: "52.0 km, 26% up.",
            source: CoachTipRewriter.source(of: loadCard)
        )
        let staleFuel = CoachTipWording(
            kind: .longRunFuel, title: "Old fuel", message: "No numbers.",
            source: "Practise your fuelling\nSomething the card no longer says."
        )
        let freshFuel = CoachTipWording(
            kind: .longRunFuel, title: "New fuel", message: "65 g and 450 ml.",
            source: CoachTipRewriter.source(of: fuelCard)
        )

        let merged = CoachTipRewriter.merging([freshFuel], into: [loadWording, staleFuel], keeping: [fuelCard, loadCard])
        #expect(merged.count == 2)
        #expect(merged.contains(freshFuel))
        #expect(merged.contains(loadWording))
        #expect(CoachTipRewriter.cardsNeedingWording([fuelCard, loadCard], existing: merged).isEmpty)
    }

    // MARK: Prompt

    @Test func promptCarriesEachCardButNotItsDerivation() {
        let prompt = CoachTipRewriter.prompt(for: [fuelCard, loadCard])
        #expect(prompt.contains("id: longRunFuel"))
        #expect(prompt.contains("id: load"))
        #expect(prompt.contains(fuelCard.message))
        #expect(!prompt.contains("g/kg/h"))
    }

    @Test func requestKeyMovesOnlyWithTheText() {
        let reordered = SmartCoachCard(
            kind: loadCard.kind, title: loadCard.title, message: loadCard.message,
            glance: loadCard.glance, tone: loadCard.tone, score: 0.9
        )
        #expect(CoachTipRewriter.requestKey(for: [loadCard]) == CoachTipRewriter.requestKey(for: [reordered]))
        #expect(CoachTipRewriter.requestKey(for: [loadCard]) != CoachTipRewriter.requestKey(for: [fuelCard]))
    }

    // MARK: Service

    @Test func serviceReturnsOnlyValidatedWordingFromTheOnDeviceModel() async {
        let recorder = TipRequestRecorder()
        let backend = TipWritingCoach(
            available: true,
            drafts: [
                CoachTipDraft(id: "load", title: "Hold it here", message: "52.0 km this week, 26% up on last."),
                fuelDraft(message: "Take 70 g an hour from forty-five minutes in, with 450 ml."),
            ],
            recorder: recorder
        )
        let service = AICoachService(onDeviceBackend: backend)

        let wording = await service.writeCoachTips(for: [fuelCard, loadCard])

        #expect(wording.map(\.kind) == [.load])
        let request = await recorder.request
        #expect(request?.useServerModel == false)
        #expect(request?.instructions == CoachTipRewriter.instructions)
        #expect(request?.prompt == CoachTipRewriter.prompt(for: [fuelCard, loadCard]))
    }

    @Test func serviceFallsBackToNothingWhenTheModelCannotHelp() async {
        let unavailable = AICoachService(
            onDeviceBackend: TipWritingCoach(available: false, drafts: [], recorder: TipRequestRecorder())
        )
        let failing = AICoachService(
            onDeviceBackend: TipWritingCoach(available: true, drafts: nil, recorder: TipRequestRecorder())
        )
        let unsupported = AICoachService(onDeviceBackend: nil)

        let fromUnavailable = await unavailable.writeCoachTips(for: [loadCard])
        let fromFailing = await failing.writeCoachTips(for: [loadCard])
        let fromUnsupported = await unsupported.writeCoachTips(for: [loadCard])
        #expect(fromUnavailable.isEmpty)
        #expect(fromFailing.isEmpty)
        #expect(fromUnsupported.isEmpty)
    }
}

// MARK: - Fake backend

private actor TipRequestRecorder {
    struct Request: Sendable {
        let instructions: String
        let prompt: String
        let useServerModel: Bool
    }

    private(set) var request: Request?

    func record(_ request: Request) {
        self.request = request
    }
}

/// Writes canned tip drafts, or throws when `drafts` is nil, and records what it was asked.
private struct TipWritingCoach: OnDeviceCoachGenerating {
    let available: Bool
    let drafts: [CoachTipDraft]?
    let recorder: TipRequestRecorder

    func isAvailable() async -> Bool { available }
    func unavailableReason() async -> String? { available ? nil : "unavailable" }

    func generateCoachTips(
        instructions: String,
        prompt: String,
        useServerModel: Bool
    ) async throws -> [CoachTipDraft] {
        await recorder.record(.init(instructions: instructions, prompt: prompt, useServerModel: useServerModel))
        guard let drafts else { throw OnDeviceCoachError.malformedResponse }
        return drafts
    }

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
        throw OnDeviceCoachError.unavailable
    }

    func generateChatReply(
        instructions: String,
        context: String,
        messages: [AIProviderChatMessage],
        useServerModel: Bool,
        onPartialText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        throw OnDeviceCoachError.unavailable
    }
}
