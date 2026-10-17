import SwiftUI

// Part of `RunSummaryView` (D1).
// The coach's one card on the run screen. The full read lives on the coach page
// (`+CoachSection`), opened from here.

extension RunSummaryView {

    // MARK: Coach summary card (on the run screen)

    /// The coach on the summary: its headline and the first thing it says to do. Every
    /// other part of the read opens on the coach page, which used to be six cards inline.
    /// Before a read exists, the card is where it is asked for.
    @ViewBuilder
    var coachSummaryCard: some View {
        if appSettings.aiInsightsEnabled {
            if aiInsight != nil || isLoadingAIInsight {
                Button {
                    openPage = .coach
                } label: {
                    coachSummaryContent(opensPage: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint(
                    String(localized: "Opens the full coaching read", comment: "Hint on the run screen's coach card")
                )
            } else {
                coachSummaryContent(opensPage: false)
            }
        }
    }

    private func coachSummaryContent(opensPage: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SparkleShape()
                    .fill(Color.brand)
                    .frame(width: 11, height: 11)
                Text("AI coach")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer()
                if opensPage {
                    StrideIcon(name: .chevronRight, size: 12, color: .secondary, strokeWeight: 2.4)
                }
            }

            if isLoadingAIInsight {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Writing your analysis…")
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                }
            } else if let aiInsight {
                Text(markdownText(aiInsight.headline))
                    .font(.dsTitle3.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if aiInsight.apiReady, let first = aiInsight.actionItems.first {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Next")
                            .font(.dsCaption.weight(.bold))
                            .foregroundStyle(Color.brandText)
                        Text(normalizedMarkdownText(first.title))
                            .font(.dsFootnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
            } else {
                Text(hasAIKey
                     ? "Get a coaching read of this run."
                     : "Turn on AI Coach in Settings to get a coaching read of this run.")
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hasAIKey {
                    Button {
                        Task { await loadAIInsight() }
                    } label: {
                        Text("Write analysis")
                    }
                    .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .strideCard()
        .contentShape(Rectangle())
    }
}
