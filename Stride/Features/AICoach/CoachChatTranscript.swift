import Foundation

// MARK: - CoachChatTranscript

/// What of the chat on screen is sent back to the model each turn (P2.5).
///
/// The backend replays the conversation as one prompt, and its prompt fitting only trims
/// the run-history block, never the conversation. Two things went wrong with sending all
/// of it:
///
/// - **Failure bubbles were replayed as the coach's words.** "I could not reach Apple
///   Intelligence…" is shown as a coach message, so the model was told it had said that.
/// - **The transcript only grew.** On the on-device model's small window a long chat
///   eventually overflowed, and from then on every message failed, because the next
///   prompt was longer still.
///
/// So the transcript leaves out anything that was not a real exchange, and keeps only the
/// most recent messages that fit a budget. The newest message, the runner's question, is
/// always kept.
enum CoachChatTranscript {

    /// One message on screen, as far as the transcript is concerned.
    struct Entry: Equatable {
        var isCoach: Bool
        var text: String
        /// A setup or failure notice rather than something either side said.
        var isNotice: Bool
    }

    /// Most messages sent back: the last four exchanges.
    static let maxMessages = 8
    /// Most characters of conversation sent back, roughly 1,500 tokens. The coach's run
    /// context and instructions share the window, and the on-device one is small.
    static let maxCharacters = 6_000

    static func providerMessages(
        from entries: [Entry],
        maxMessages: Int = maxMessages,
        maxCharacters: Int = maxCharacters
    ) -> [AIProviderChatMessage] {
        var kept: [Entry] = []
        var characters = 0
        for entry in entries.reversed() where !entry.isNotice {
            guard kept.count < maxMessages else { break }
            // The newest message always goes, however long: it is the one being answered.
            if !kept.isEmpty, characters + entry.text.count > maxCharacters { break }
            kept.append(entry)
            characters += entry.text.count
        }
        return kept.reversed().map {
            AIProviderChatMessage(role: $0.isCoach ? "assistant" : "user", content: $0.text)
        }
    }
}
