import SwiftUI

// MARK: - SmartCoachCardsSection

/// The dashboard's coaching strip: one primary card and up to two supporting ones.
///
/// The hierarchy is the point. Three equally-sized cards made the ranking invisible —
/// nothing told the runner which of them actually mattered, so the scoring in
/// ``SmartCoachCards`` was doing work nobody could see. The top card is now drawn larger,
/// tinted, and carries its derivation line; the rest sit compact underneath.
///
/// Renders whatever the service produced and decides nothing itself: which rules fire, in
/// what order, and in what words all live where they are testable.
struct SmartCoachCardsSection: View {
    let cards: [SmartCoachCard]

    private var primary: SmartCoachCard? { cards.first }
    private var supporting: ArraySlice<SmartCoachCard> { cards.dropFirst() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StrideIcon(name: .bolt, size: 12, color: .brand, strokeWeight: 2.4)
                Text("Coach Tips")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.xs)

            if let primary {
                PrimaryCoachCardView(card: primary)
            }
            ForEach(supporting) { card in
                SupportingCoachCardView(card: card)
            }
        }
    }
}

// MARK: - Primary

private struct PrimaryCoachCardView: View {
    let card: SmartCoachCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                CoachCardIcon(card: card, size: 44, glyph: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: card.categoryLabel)
                        .font(.dsCaption2.weight(.bold))
                        .kerning(1.2)
                        .foregroundStyle(.secondary)
                    Text(card.title)
                        .font(.dsHeadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Text(card.message)
                .font(.dsSubhead)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let derivation = card.derivation {
                derivationLine(derivation)
            }
        }
        .padding(18)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The working behind the card's numbers.
    ///
    /// Shown only on the primary. A computed figure with no visible basis reads as a
    /// guess, and this is the card the runner is actually being asked to act on — the
    /// supporting two are context, and three derivation lines would bury all of them.
    private func derivationLine(_ derivation: String) -> some View {
        Text(verbatim: derivation)
            .font(.dsCaption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: AppRadius.lg)
            .fill(
                LinearGradient(
                    colors: [card.tint.opacity(0.14), card.tint.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(card.tint.opacity(0.25), lineWidth: 0.5)
            )
    }

    /// The derivation is read last and only after the advice: it is the reason to trust
    /// the number, not part of the instruction.
    private var accessibilityDescription: String {
        [card.title, card.message, card.derivation]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}

// MARK: - Supporting

private struct SupportingCoachCardView: View {
    let card: SmartCoachCard

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoachCardIcon(card: card, size: 32, glyph: 15)
            VStack(alignment: .leading, spacing: 3) {
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
        .padding(14)
        .strideCard(cornerRadius: AppRadius.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title). \(card.message)")
    }
}

// MARK: - Icon

private struct CoachCardIcon: View {
    let card: SmartCoachCard
    let size: CGFloat
    let glyph: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(card.tint.opacity(0.15))
                .frame(width: size, height: size)
            StrideIcon(name: card.icon, size: glyph, color: card.tint, strokeWeight: 2.2)
        }
    }
}

// MARK: - Card presentation
//
// Kept out of the model: `SmartCoachCard` is Foundation-only so the selection stays
// unit-testable without SwiftUI, the same split `WidgetSnapshot` makes with its `Tint`.

private extension SmartCoachCard {

    /// The overline text. Defined on `Category` in the model rather than here, because
    /// the widget snapshot ships the same string — see `WidgetSnapshot.CoachTip`.
    var categoryLabel: String { category.label }

    var icon: StrideIconName {
        switch kind {
        case .raceDay, .raceWeek:  return .trophy
        case .refuel:              return .heart
        case .longRunFuel:         return .flame
        case .sessionFuel:         return .flame
        case .heat:                return .tempo
        case .restDay:             return .moon
        case .fade:                return .chart
        case .polarization:        return .tortoise
        case .cadence:             return .timer
        case .load:                return .mountain
        case .readiness:           return .moon
        case .comeback:            return .run
        case .prep:                return .check
        case .planStartsSoon:      return .calendar
        case .planFinished:        return .flag
        case .noPlan:              return .plus
        }
    }

    /// Tone drives the colour rather than kind, so a caution reads as one wherever it
    /// came from and the palette stays the app's own.
    var tint: Color {
        switch tone {
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
                Tomorrow's Long Run goes past the point where you have to eat on the move. \
                Start it topped up, then take 65 g an hour from about forty-five minutes \
                in, with 450 ml an hour of fluid.
                """,
                glance: "65 g an hour from forty-five minutes in, with 450 ml an hour of fluid.",
                tone: .neutral,
                score: 0.6,
                derivation: "0.9 g/kg/h · 72 kg · ~1.9 h · 123 g total"
            ),
            SmartCoachCard(
                kind: .load,
                title: "Big week — hold it there",
                message: "You've covered 52.0 km in the last seven days, 26% up on the seven before.",
                glance: "Volume is up sharply. Hold it here for a week before adding more.",
                tone: .caution,
                score: 0.42
            ),
            SmartCoachCard(
                kind: .polarization,
                title: "Let the easy days be easy",
                message: "Your easy runs are averaging 5:12 min/km — only 4% slower than your hard ones.",
                glance: "Hold the easy days 30–45 seconds per km further back.",
                tone: .neutral,
                score: 0.31
            ),
        ])
        .padding()
    }
}
