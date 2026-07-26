import SwiftUI

// Part of `RunSummaryView` (D1).
// The coach entry point at the top of the screen: the headline, the confidence badge,
// and what tapping it does depending on whether an insight has been generated yet.

extension RunSummaryView {

    // MARK: Top AI Coach access

    var aiCoachAccessCard: some View {
        Button {
            handleTopCoachCardTap()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(.white)
                        .frame(width: 42, height: 42)
                        .appGlow(.subtle, color: .brand)
                    if isLoadingAIInsight {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.brand)
                    } else {
                        SparkleShape()
                            .fill(Color.brand)
                            .frame(width: 18, height: 18)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("AI COACH")
                            .font(.dsCaption2.weight(.heavy))
                            .kerning(1.4)
                            .foregroundStyle(.brand)
                        Circle()
                            .fill(Color.brand)
                            .frame(width: 5, height: 5)
                        Text(topCoachBadgeText)
                            .font(.dsCaption2.weight(.bold))
                            .kerning(0.6)
                            .foregroundStyle(.brand)
                    }

                    Text(topCoachHeadline)
                        .font(.dsSubhead.weight(.bold))
                        .kerning(-0.2)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let confidence = topCoachConfidence {
                        HStack(spacing: 6) {
                            Capsule()
                                .fill(Color.brand.opacity(0.18))
                                .frame(width: 50, height: 3)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.brand)
                                        .frame(width: 50 * CGFloat(confidence) / 100, height: 3)
                                }
                            Text("\(confidence)% conf.")
                                .font(.dsCaption2.weight(.bold).monospaced())
                                .foregroundStyle(.brand)
                        }
                    }
                }

                Spacer(minLength: 8)
                StrideIcon(name: .chevronRight, size: 14, color: .brand, strokeWeight: 2.4)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color.brand.opacity(0.20), Color.brand.opacity(0.075)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: AppRadius.lg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.brand.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("AI Coach")
        .accessibilityHint(topCoachAccessibilityHint)
    }

    private var topCoachBadgeText: String {
        guard appSettings.aiInsightsEnabled else { return "SETUP" }
        if isLoadingAIInsight { return "LOADING" }
        return aiInsight?.apiReady == true ? "READY" : "NEW"
    }

    private var topCoachHeadline: String {
        if let aiInsight, aiInsight.apiReady {
            let headline = normalizedMarkdownText(aiInsight.headline)
            return headline.isEmpty ? "Analysis ready. Ask a follow-up." : headline
        }
        if appSettings.aiInsightsEnabled, hasAIKey {
            return "Get a coaching read, evidence, and next-session actions."
        }
        return "Turn on AI Coach to ask follow-ups about this run."
    }

    private var topCoachConfidence: Int? {
        guard let aiInsight, aiInsight.apiReady else { return nil }
        return aiInsight.confidence
    }

    private var topCoachAccessibilityHint: String {
        if aiInsight?.apiReady == true {
            return "Opens AI Coach chat for this workout."
        }
        return "Loads AI Coach analysis for this workout."
    }

    @MainActor
    private func handleTopCoachCardTap() {
        if aiInsight?.apiReady == true {
            coachChatRequest = AICoachChatRequest(prompt: "Walk me through your coaching read for this run.")
            return
        }

        guard appSettings.aiInsightsEnabled, hasAIKey else {
            coachChatRequest = AICoachChatRequest(prompt: "What should I learn from this run?")
            return
        }

        Task {
            await loadAIInsight()
        }
    }
}
