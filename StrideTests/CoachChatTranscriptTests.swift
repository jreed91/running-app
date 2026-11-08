import Foundation
import Testing
@testable import Stride

// MARK: - Coach chat transcript (P2.5)
//
// What of the chat on screen goes back to the model each turn. Failure and setup notices
// were replayed as the coach's own words, and the whole conversation was sent every turn,
// so a long chat on the on-device model overflowed and then failed on every message.

struct CoachChatTranscriptTests {

    private typealias Entry = CoachChatTranscript.Entry

    private func runner(_ text: String) -> Entry { Entry(isCoach: false, text: text, isNotice: false) }
    private func coach(_ text: String) -> Entry { Entry(isCoach: true, text: text, isNotice: false) }
    private func notice(_ text: String) -> Entry { Entry(isCoach: true, text: text, isNotice: true) }

    @Test("Setup and failure notices are never sent back as the coach's words")
    func noticesAreLeftOut() {
        let sent = CoachChatTranscript.providerMessages(from: [
            runner("How was my long run?"),
            notice("I could not reach Apple Intelligence."),
            runner("How was my long run?")
        ])

        #expect(sent.map(\.content) == ["How was my long run?", "How was my long run?"])
        #expect(sent.map(\.role) == ["user", "user"])
    }

    @Test("Only the most recent messages are sent, oldest first")
    func keepsTheMostRecentMessages() {
        let entries = (1...12).map { $0.isMultiple(of: 2) ? coach("c\($0)") : runner("r\($0)") }

        let sent = CoachChatTranscript.providerMessages(from: entries, maxMessages: 4)

        #expect(sent.map(\.content) == ["r9", "c10", "r11", "c12"])
        #expect(sent.map(\.role) == ["user", "assistant", "user", "assistant"])
    }

    @Test("Older messages past the character budget are dropped; the newest is always kept")
    func characterBudget() {
        let long = String(repeating: "a", count: 50)

        let sent = CoachChatTranscript.providerMessages(
            from: [runner("old question"), coach(long), runner(long)],
            maxCharacters: 60
        )
        #expect(sent.map(\.content) == [long])

        let oversized = String(repeating: "b", count: 100)
        let alone = CoachChatTranscript.providerMessages(from: [runner(oversized)], maxCharacters: 60)
        #expect(alone.map(\.content) == [oversized])
    }
}
