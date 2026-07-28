import AppIntents
import SwiftData
import SwiftUI

/// "What should I eat before my run?" — the coach's top card, spoken.
///
/// Answers from `SmartCoachCards`, the same selection the dashboard's Coach Tips strip
/// and the Home Screen widget use. Intents open the app's own store, so this one calls it
/// directly rather than reading a published snapshot the way the widget extension must.
struct CoachTipIntent: AppIntent {
    static let title: LocalizedStringResource = "Coach Tip"
    static let description = IntentDescription("Ask what to do about your next run, and what to eat before it.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let unit = AppSettings.syncedUnitPreference()
        let container = try IntentDataProvider.makeContainer()
        let actor = IntentModelActor(modelContainer: container)
        let card = try await actor.coachTip(unit: unit)

        return .result(dialog: IntentDialog(stringLiteral: Self.dialogText(for: card))) {
            CoachTipIntentView(card: card)
        }
    }

    /// The spoken answer.
    ///
    /// Uses the card's `glance` rather than its `message` for the same reason the widget
    /// does: the dashboard's copy runs to three or four sentences, which is a paragraph
    /// to read aloud, and its wording can carry a clock ("about 30 minutes ago") that
    /// would be wrong by the time Siri got to it. The title is dropped — it is a heading
    /// for a card, and spoken before the advice it just delays the answer.
    static func dialogText(for card: SmartCoachCard?) -> String {
        guard let card else {
            return String(
                localized: "Nothing to flag right now — log a run or build a plan and I'll have more to say.",
                comment: "Siri answer when the coach has no card to offer"
            )
        }
        return card.glance
    }
}

// MARK: - Snippet

struct CoachTipIntentView: View {
    let card: SmartCoachCard?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: symbolName)
                    .font(.title2)
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: overline)
                    .font(.caption2.weight(.bold))
                    .kerning(1.2)
                    .foregroundStyle(.secondary)
                Text(verbatim: title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: CoachTipIntent.dialogText(for: card))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    // MARK: Presentation
    //
    // Reuses the widget's SF Symbol and tone mappings rather than a third set: a snippet
    // is closer to a widget card than to the dashboard's `StrideIcon` canvas glyphs, and
    // three mappings of the same eleven kinds is two too many.

    private var overline: String {
        card?.category.label ?? String(localized: "COACH", comment: "Siri snippet overline with no card")
    }

    private var title: String {
        card?.title ?? String(localized: "Nothing to flag", comment: "Siri snippet title with no card")
    }

    private var symbolName: String {
        card.map { WidgetSnapshotBuilder.symbolName(for: $0.kind) } ?? "figure.run"
    }

    private var tint: Color {
        switch card?.tone {
        case .positive: return .success
        case .caution:  return .warning
        case .neutral:  return .brand
        case nil:       return .brand
        }
    }
}
