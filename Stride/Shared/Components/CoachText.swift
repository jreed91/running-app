import SwiftUI

/// The coach's reply, laid out the way it was written.
///
/// A coach reply is prose with the occasional list in it, and it used to reach the
/// screen as a single `Text`: paragraphs ran together, and every `- ` and `1. ` after
/// the first line showed up as a literal marker mid-sentence, because
/// `CoachMarkdown.attributed(_:)` only ever sees the start of the string it is handed.
/// This renders each block of the reply as itself — paragraphs spaced apart, list items
/// with a real bullet and a hanging indent — so a reply can be skimmed rather than read
/// end to end.
///
/// Font and colour are inherited, so the caller styles this exactly as it styled the
/// `Text` it replaces.
struct CoachText: View {
    private let text: String
    private let blockSpacing: CGFloat

    init(_ text: String, blockSpacing: CGFloat = 10) {
        self.text = text
        self.blockSpacing = blockSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(CoachMarkdown.blocks(text)) { block in
                blockView(block)
            }
        }
        // One reply, one VoiceOver element. Splitting the reply into blocks would
        // otherwise split it into a dozen things to swipe through, where the single
        // `Text` this replaces was read straight out in one go.
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func blockView(_ block: CoachMarkdown.Block) -> some View {
        switch block.kind {
        case .paragraph:
            prose(block.text)
        case .heading:
            // Bolded rather than resized: the caller chose the type scale for this
            // context — a chat bubble and the full-analysis card are not the same
            // size — and a heading is a heading at whatever size it is set in.
            prose(block.text)
                .fontWeight(.bold)
        case .bullet:
            listRow(marker: "•", block.text)
        case .numbered(let number):
            listRow(marker: "\(number).", block.text)
        }
    }

    private func prose(_ text: String) -> some View {
        Text(CoachMarkdown.attributed(text))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A list item: the marker in its own column so a wrapped item lines up under its
    /// own text rather than under the bullet.
    private func listRow(marker: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .monospacedDigit()
                .opacity(0.7)
            prose(text)
        }
    }
}

#Preview {
    CoachText(
        """
        ## This week
        You held 5:20 per km for the whole run, which is about 15 seconds quicker than \
        your usual easy pace.

        - Keep tomorrow easy, around 6:10 per km.
        - Drink before you head out — it was 24°C.

        1. Warm up for 10 minutes.
        2. Run 4 x 800m at 4:45 per km.
        """
    )
    .font(.subheadline)
    .padding()
}
