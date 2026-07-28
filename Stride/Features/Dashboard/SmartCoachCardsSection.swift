import SwiftUI

// MARK: - SmartCoachCardsSection

/// The dashboard's coaching strip: what to eat before the next session, and what the
/// last few runs suggest changing about it.
///
/// Renders whatever ``SmartCoachCards`` produced and decides nothing itself — which rules
/// fire, in which order, and in what words all live in the service, where they are
/// testable.
struct SmartCoachCardsSection: View {
    let cards: [SmartCoachCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StrideIcon(name: .bolt, size: 12, color: .brand, strokeWeight: 2.4)
                Text("Coach Tips")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.xs)

            ForEach(cards) { card in
                SmartCoachCardView(card: card)
            }
        }
    }
}

// MARK: - SmartCoachCardView

private struct SmartCoachCardView: View {
    let card: SmartCoachCard

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 40, height: 40)
                StrideIcon(name: icon, size: 18, color: tint, strokeWeight: 2.2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(categoryLabel)
                    .font(.dsCaption2.weight(.bold))
                    .kerning(1.2)
                    .foregroundStyle(.secondary)
                Text(card.title)
                    .font(.bodyStrong)
                    .fixedSize(horizontal: false, vertical: true)
                Text(card.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
        )
        // Combined rather than left as three loose fragments — the overline is a category
        // marker, not a sentence, and VoiceOver reading "FUEL" on its own says nothing.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title). \(card.message)")
    }

    // MARK: Styling
    //
    // Kept in the view rather than on the model: `SmartCoachCard` is Foundation-only so
    // the rules stay unit-testable without SwiftUI, the same split `WidgetSnapshot` makes
    // with its `Tint`.

    private var categoryLabel: LocalizedStringKey {
        switch card.category {
        case .nutrition: return "FUEL"
        case .training:  return "TRAINING"
        }
    }

    private var icon: StrideIconName {
        switch card.kind {
        case .raceWeek:     return .trophy
        case .refuel:       return .heart
        case .longRunFuel:  return .flame
        case .sessionFuel:  return .flame
        case .heat:         return .tempo
        case .fade:         return .chart
        case .polarization: return .tortoise
        case .cadence:      return .timer
        case .load:         return .mountain
        case .comeback:     return .run
        case .prep:         return .check
        }
    }

    /// Tone drives the colour rather than kind, so a caution reads as one wherever it
    /// came from and the palette stays the app's own zone colours.
    private var tint: Color {
        switch card.tone {
        case .positive: return .success
        case .neutral:  return .brand
        case .caution:  return .warning
        }
    }
}

#Preview {
    ScrollView {
        SmartCoachCardsSection(cards: [
            SmartCoachCard(
                kind: .longRunFuel,
                title: "Practise your fuelling",
                message: """
                Tomorrow's Long Run is 18.0 km. Start it topped up, then take thirty to \
                sixty grams of carbohydrate an hour from about forty-five minutes in.
                """,
                tone: .neutral
            ),
            SmartCoachCard(
                kind: .polarization,
                title: "Let the easy days be easy",
                message: """
                Your easy runs are averaging 5:12 min/km — only 4% slower than your hard \
                ones (5:00 min/km).
                """,
                tone: .neutral
            ),
            SmartCoachCard(
                kind: .load,
                title: "Big week — hold it there",
                message: "You've covered 52.0 km in the last seven days, 26% up on the seven before.",
                tone: .caution
            ),
        ])
        .padding()
    }
}
