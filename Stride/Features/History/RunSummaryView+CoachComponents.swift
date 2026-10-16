import SwiftUI

// Part of `RunSummaryView` (D1).
// Small view types used only by the coach cards.

extension RunSummaryView {

    struct AICoachChatRequest: Identifiable {
        let id = UUID()
        let prompt: String?
    }

    struct SparkleShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.midY - rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.midY + rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.midY + rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.midY - rect.height * 0.12))
            path.closeSubpath()
            return path
        }
    }

    struct AIActionCard: View {
        let number: String
        let title: String
        let detail: String
        let metric: String?
        let tone: Color

        var bodyView: some View {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: AppRadius.micro)
                    .fill(tone)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(number)
                            .font(.dsCaption2.weight(.bold).monospacedDigit())
                            .kerning(0.6)
                            .foregroundStyle(tone)
                        Text(Self.markdownText(title))
                            .font(.dsSubhead.weight(.bold))
                            .kerning(-0.2)
                    }
                    Text(Self.markdownText(detail))
                        .font(.dsFootnote)
                        .lineSpacing(1)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                if let metric {
                    Text(metric)
                        .font(.dsCaption.weight(.bold).monospacedDigit())
                        .foregroundStyle(tone)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.xs))
                }
            }
            .padding(14)
            .strideCard(cornerRadius: AppRadius.md)
        }

        var body: some View {
            bodyView
        }

        private static func markdownText(_ text: String) -> AttributedString {
            CoachMarkdown.attributed(text)
        }
    }
}
