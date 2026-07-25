import Foundation

// MARK: - SmartAdaptSummaryStream

/// Reads the coach's per-workout summaries out of a **partial** JSON response while it
/// is still streaming in.
///
/// Smart Adapt shows the coach's reasoning as it arrives, which means parsing a
/// document that is by definition incomplete — `JSONDecoder` cannot help until the last
/// byte lands, and by then there is nothing left to stream. So this walks the buffer
/// looking for the `"summary"` array and returns every string element that has been
/// closed so far, ignoring the half-written one at the end.
///
/// `PlanTabView` owned this scanner (D1): a character-level state machine sitting in a
/// SwiftUI view, where the escape handling, the "stop at the closing bracket" rule, and
/// the "a key called summary might appear before the array" assumption had no test home.
/// It is pure and stateless — the caller keeps the buffer.
enum SmartAdaptSummaryStream {

    /// Every completed summary string in `text`, in document order.
    ///
    /// Returns an empty array while the buffer has not yet reached the array (or has
    /// reached it but closed no element), which the caller shows as "reading coach
    /// summary…" rather than as an empty result.
    ///
    /// - Note: Only the escapes JSON actually needs for this payload are decoded
    ///   (`\n`, `\r`, `\t`, and any escaped literal such as `\"` or `\\`). A `\uXXXX`
    ///   sequence is passed through as its literal characters; the coach's summaries
    ///   are plain prose and the buffer is discarded as soon as the stream finishes.
    static func summaries(in text: String) -> [String] {
        guard let keyRange = text.range(of: summaryKey),
              let arrayStart = text[keyRange.upperBound...].firstIndex(of: "[") else {
            return []
        }

        var summaries: [String] = []
        var current = ""
        var isInsideString = false
        var isEscaping = false
        var index = text.index(after: arrayStart)

        while index < text.endIndex {
            let character = text[index]

            if isInsideString {
                if isEscaping {
                    switch character {
                    case "n": current.append("\n")
                    case "r": current.append("\r")
                    case "t": current.append("\t")
                    default: current.append(character)
                    }
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    // The element closed, so it is safe to publish. A summary that is
                    // only whitespace carries nothing and would render as a blank bullet.
                    let summary = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !summary.isEmpty {
                        summaries.append(summary)
                    }
                    current = ""
                    isInsideString = false
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "]" {
                break
            }

            text.formIndex(after: &index)
        }

        return summaries
    }

    /// How many of the most recent summaries the progress card shows at once.
    static let displayLimit = 4

    private static let summaryKey = "\"summary\""
}
