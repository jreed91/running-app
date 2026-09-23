import Foundation

// MARK: - Model output

/// One coaching tip as Apple's model wrote it, before anything has checked it.
///
/// Plain strings so `OnDeviceCoachGenerating` can hand it across without the caller
/// importing `FoundationModels` — the same split every other coach output makes.
struct CoachTipDraft: Sendable, Equatable {
    /// The card's `SmartCoachCard.Kind` raw value, as the model copied it back.
    let id: String
    let title: String
    let message: String
}

/// A model-written title and message that passed ``CoachTipRewriter/validated(_:for:)``,
/// bound to the exact card text it was written from.
struct CoachTipWording: Sendable, Equatable {
    let kind: SmartCoachCard.Kind
    let title: String
    let message: String
    /// The card's hard-coded title and message this wording replaces. A wording is only
    /// ever drawn over a card whose text still matches, so a tip written for "Tomorrow's
    /// Long Run" never lands on Thursday's, and one written for a gym day never lands on
    /// the `.prep` card for an easy run.
    let source: String
}

// MARK: - CoachTipRewriter

/// Lets Apple Intelligence write the dashboard's Coach Tips in its own words, while
/// ``SmartCoachCards`` keeps deciding *what* they say.
///
/// The split is deliberate. The selection, the scores and every computed amount stay
/// deterministic and tested — that is advice about eating and training, and it is what
/// the widget and Siri read. The model only rewrites the wording of cards already
/// chosen, and a rewrite is thrown away unless it carries exactly the same numbers as
/// the card it replaces. So the worst a bad generation can do is fall back to the
/// hard-coded copy, which is also what shows while the model writes and on any device
/// without Apple Intelligence.
///
/// Only `title` and `message` are rewritten. `glance` stays hard-coded because it goes
/// into `WidgetSnapshot`, where text that changes on every write spends a WidgetKit
/// reload; `derivation` stays because it is the working behind the numbers.
///
/// Pure: the generation itself is `AICoachService.writeCoachTips(for:)`.
enum CoachTipRewriter {

    /// Longest title and message accepted. Generous against the hard-coded copy (the
    /// longest message is about 370 characters) so a slightly wordier rewrite still
    /// lands, but short enough that a runaway one does not take over the Home tab.
    static let maximumTitleLength = 60
    static let maximumMessageLength = 480

    static let instructions = """
    You are Stride's running coach, writing the short tips on the runner's home screen.

    The app has already chosen each tip and worked out its numbers. Rewrite each one in \
    your own words so it reads like a coach talking to this runner: say "you", use \
    everyday words, keep each sentence to one idea, and lead with what to do.

    Keep the advice exactly the same. Do not add advice, foods, products, facts or \
    numbers that are not in the tip, and do not leave any out. Copy every number, amount \
    and unit exactly as it is written, and write no other numbers.

    Return one tip per id, copying each id exactly. Keep each title under six words and \
    each message to two or three short sentences. No lists, headings or emoji. Give no \
    medical advice, and never mention that you are an AI.
    """

    /// The tips to rewrite, one block per card, in strip order.
    ///
    /// Leaves out `derivation`: its figures ("0.9 g/kg/h · 72 kg") are working the
    /// message does not quote, and a rewrite that picked one up would fail the number
    /// check below and be thrown away.
    static func prompt(for cards: [SmartCoachCard]) -> String {
        let blocks = cards.map { card in
            """
            id: \(card.kind.rawValue)
            topic: \(card.category.rawValue)
            title: \(card.title)
            message: \(card.message)
            """
        }
        return """
        Rewrite these coaching tips.

        \(blocks.joined(separator: "\n\n"))
        """
    }

    /// What a card's wording is bound to — see ``CoachTipWording/source``.
    static func source(of card: SmartCoachCard) -> String {
        "\(card.title)\n\(card.message)"
    }

    /// Changes whenever any card's text does, and only then. The dashboard keys its
    /// generation task on this, so a render that leaves the cards alone asks for nothing.
    static func requestKey(for cards: [SmartCoachCard]) -> [String] {
        cards.map { "\($0.kind.rawValue)\n\(source(of: $0))" }
    }

    /// The cards that have no wording written from their current text yet.
    static func cardsNeedingWording(
        _ cards: [SmartCoachCard],
        existing: [CoachTipWording]
    ) -> [SmartCoachCard] {
        cards.filter { Self.wording(for: $0, in: existing) == nil }
    }

    /// The drafts that are safe to show, bound to the card each was written for.
    ///
    /// A draft is dropped — and its card keeps the hard-coded copy — when it names no
    /// card in `cards`, repeats one already answered, is blank or overlong, or when its
    /// numbers differ from the card's in either direction. The number check is what makes
    /// letting a model near nutrition advice acceptable: "65 g an hour" cannot quietly
    /// become "80 g an hour", and no figure the app did not compute can appear.
    static func validated(_ drafts: [CoachTipDraft], for cards: [SmartCoachCard]) -> [CoachTipWording] {
        var accepted: [CoachTipWording] = []
        for draft in drafts {
            let id = draft.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let card = cards.first(where: { $0.kind.rawValue == id }),
                  !accepted.contains(where: { $0.kind == card.kind }) else { continue }

            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = draft.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= maximumTitleLength,
                  !message.isEmpty, message.count <= maximumMessageLength else { continue }

            let original = numbers(in: card.title).union(numbers(in: card.message))
            let rewritten = numbers(in: title).union(numbers(in: message))
            guard original == rewritten else { continue }

            accepted.append(
                CoachTipWording(kind: card.kind, title: title, message: message, source: source(of: card))
            )
        }
        return accepted
    }

    /// `fresh` on top of whatever in `existing` still matches one of `cards`.
    ///
    /// Keeps the wording of cards that did not change while another one did, so a single
    /// card moving does not flip the whole strip back to the hard-coded copy. Anything
    /// written for text no longer on screen is dropped rather than left to accumulate.
    static func merging(
        _ fresh: [CoachTipWording],
        into existing: [CoachTipWording],
        keeping cards: [SmartCoachCard]
    ) -> [CoachTipWording] {
        let current = Set(cards.map { Self.source(of: $0) })
        let kept = existing.filter { old in
            current.contains(old.source) && !fresh.contains(where: { $0.kind == old.kind })
        }
        return (fresh + kept).filter { current.contains($0.source) }
    }

    /// `cards` with each one's title and message replaced by its wording, where it has
    /// one written from its current text. Everything else about the card — kind, score,
    /// tone, glance, derivation, expiry — is untouched, so ordering and every other
    /// surface are exactly what they would be without the model.
    static func apply(_ wordings: [CoachTipWording], to cards: [SmartCoachCard]) -> [SmartCoachCard] {
        cards.map { card in
            guard let rewrite = Self.wording(for: card, in: wordings) else { return card }
            return SmartCoachCard(
                kind: card.kind,
                title: rewrite.title,
                message: rewrite.message,
                glance: card.glance,
                tone: card.tone,
                score: card.score,
                derivation: card.derivation,
                expiresAt: card.expiresAt
            )
        }
    }

    /// Every number written in digits in `text`: "5:12", "52.0", "26", and both ends of
    /// "60–90". Numbers spelled as words ("forty-five") are not seen; the instructions
    /// ask for those to be copied as written, and a rewrite that turns one into digits
    /// fails the check, which errs the safe way.
    static func numbers(in text: String) -> Set<String> {
        var found: Set<String> = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else if !current.isEmpty,
                      numberSeparators.contains(character),
                      index + 1 < characters.count,
                      characters[index + 1].isASCII,
                      characters[index + 1].isNumber {
                // A separator inside a number ("5:12", "52.0", "1,200") belongs to it; a
                // full stop or comma after one ("26. Then", "26, then") does not.
                current.append(character)
            } else if !current.isEmpty {
                found.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { found.insert(current) }
        return found
    }

    private static let numberSeparators: Set<Character> = [".", ",", ":"]

    private static func wording(for card: SmartCoachCard, in wordings: [CoachTipWording]) -> CoachTipWording? {
        let text = Self.source(of: card)
        return wordings.first { $0.kind == card.kind && $0.source == text }
    }
}
