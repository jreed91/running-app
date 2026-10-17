import SwiftUI
import SwiftData

// Part of `RunSummaryView` (D1).
// The AI coach section proper — the coaching read, the ask-the-coach card, the action
// plan, the next-session suggestion, the reaction row, and the empty/unavailable states.

extension RunSummaryView {

    // MARK: AI coach section

    @ViewBuilder
    var aiCoachSection: some View {
        if appSettings.aiInsightsEnabled {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            SparkleShape()
                                .fill(Color.brand)
                                .frame(width: 11, height: 11)
                            Text("AI coach")
                                .strideEyebrow()
                                .foregroundStyle(.secondary)
                        }
                        Text("Today's analysis")
                            .font(.dsHeadline.weight(.bold))
                            .kerning(-0.3)
                    }
                    Spacer()
                    Button {
                        Task {
                            await loadAIInsight()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            SparkleShape()
                                .fill(Color.brand)
                                .frame(width: 11, height: 11)
                            Text(aiInsight == nil ? "Load" : "Refresh")
                        }
                    }
                    .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
                    .disabled(isLoadingAIInsight || !hasAIKey)
                    .accessibilityHint(coachLoadDisabledHint)
                }
                .padding(.horizontal, AppSpacing.xs)

                if isLoadingAIInsight {
                    // Show the coach's text the moment it arrives instead of a skeleton
                    // over an already-populated buffer (N22).
                    if aiStreamBuffer.isEmpty {
                        aiCoachSkeletonSection
                    } else {
                        aiStreamingPreviewCard
                    }
                } else if let aiInsight {
                    if aiInsight.apiReady {
                        aiCoachingReadCard(aiInsight)
                        aiAskCoachCard
                        aiActionPlan(aiInsight)
                        aiNextSessionCard(aiInsight)
                        aiReactionRow(aiInsight)
                        aiAttribution(aiInsight)
                    } else {
                        aiUnavailableCard(aiInsight)
                    }
                } else {
                    aiEmptyState
                }
            }
            .padding(.top, AppSpacing.sm)
        }
    }

    /// Why Load/Refresh is greyed out, for VoiceOver; empty while it can be tapped.
    private var coachLoadDisabledHint: String {
        if !hasAIKey {
            return String(
                localized: "Turn on AI Coach in Settings to load an analysis.",
                comment: "Accessibility hint on the disabled coach Load button"
            )
        }
        if isLoadingAIInsight {
            return String(
                localized: "The analysis is already loading.",
                comment: "Accessibility hint on the coach Load button while it loads"
            )
        }
        return ""
    }

    private func aiCoachingReadCard(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: 8) {
                SparkleShape()
                    .fill(Color.brand)
                    .frame(width: 14, height: 14)
                Text("Coaching read")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer()
                confidenceChip(insight.confidence)
            }

            Text(markdownText(insight.headline))
                .font(.dsTitle2.weight(.heavy))
                .kerning(-0.55)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(insight.evidence, id: \.self) { item in
                    evidenceChip(
                        label: "\(normalizedMarkdownText(item.label)) \(normalizedMarkdownText(item.value))",
                        sub: item.delta.map(normalizedMarkdownText),
                        tone: aiTone(item.tone)
                    )
                }
            }
        }
        .padding(AppSpacing.lg)
        // A card, not a warning: the amber ground read as an alert on every summary.
        .strideCard()
    }

    private var aiAskCoachCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask coach")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(postRunCoachPrompts, id: \.self) { prompt in
                        Button {
                            coachChatRequest = AICoachChatRequest(prompt: prompt)
                        } label: {
                            Text(prompt)
                        }
                        .buttonStyle(.strideChip())
                    }
                }
            }
            .scrollClipDisabled()

            Button {
                coachChatRequest = AICoachChatRequest(prompt: nil)
            } label: {
                HStack(spacing: 10) {
                    SparkleShape()
                        .fill(Color.brand)
                        .frame(width: 13, height: 13)
                    Text("Ask your coach...")
                        .font(.dsFootnote)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "arrow.up")
                        .font(.dsCaption.weight(.bold))
                        .foregroundStyle(.onFill)
                        .frame(width: 30, height: 30)
                        .background(.route, in: Circle())
                }
                .padding(.leading, AppSpacing.md)
                .padding(.trailing, AppSpacing.sm)
                .padding(.vertical, AppSpacing.sm)
                .background(.surfaceSecondary, in: Capsule())
                .overlay(Capsule().strokeBorder(.cardStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, AppSpacing.xxs)
    }

    private func aiActionPlan(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Do this next")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)

            let actions = Array(insight.actionItems.prefix(3))
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                AIActionCard(
                    number: String(format: "%02d", index + 1),
                    title: normalizedMarkdownText(action.title),
                    detail: normalizedMarkdownText(action.detail),
                    metric: action.metric.map(normalizedMarkdownText),
                    tone: aiTone(action.tone ?? action.priority)
                )
            }
        }
        .padding(.top, 6)
    }

    private func aiNextSessionCard(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await applyNextSessionFeedback(insight) }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.success.opacity(0.14))
                            .frame(width: 40, height: 40)
                        if isApplyingNextSessionFeedback {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.success)
                        } else {
                            StrideIcon(name: .run, size: 20, color: .success, strokeWeight: 2)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next session")
                            .strideEyebrow()
                            .foregroundStyle(.secondary)
                        Text(markdownText(insight.nextWorkoutSuggestion))
                            .font(.dsSubhead.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let rationale = insight.nextWorkoutRationale?.trimmingCharacters(in: .whitespacesAndNewlines), !rationale.isEmpty {
                            Text(markdownText(rationale))
                                .font(.dsCaption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    StrideIcon(name: .chevronRight, size: 14, color: .secondary, strokeWeight: 2.4)
                }
            }
            .buttonStyle(.plain)
            .disabled(isApplyingNextSessionFeedback || !canApplyNextSessionFeedback)

            if let nextSessionUpdateMessage {
                Text(nextSessionUpdateMessage)
                    .font(.dsCaption.weight(.medium))
                    .foregroundStyle(nextSessionUpdateMessage.hasPrefix("Updated") ? Color.success : Color.secondary)
                    .padding(.horizontal, AppSpacing.xxs)
            }
        }
        .padding(AppSpacing.md)
        .strideCard(cornerRadius: AppRadius.md)
    }

    private func aiReactionRow(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(AppAnimation.snappy) {
                        showFullAIAnalysis.toggle()
                    }
                } label: {
                    Text(showFullAIAnalysis ? "Hide full analysis" : "Read full analysis")
                }
                .buttonStyle(.strideButton(.quiet))

                reactionButton(.up)
                reactionButton(.down)
            }

            if showFullAIAnalysis {
                fullAnalysisCard(insight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func fullAnalysisCard(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Full analysis")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            CoachText(CoachInsightText.fullAnalysis(for: insight))
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .strideCard(cornerRadius: AppRadius.md)
    }

    /// Thumbs-up/down on the coach insight, stored on the run (N22).
    ///
    /// The rating used to live in view state that nothing read — not persisted, not sent
    /// anywhere, gone on dismiss. It now survives, and a second tap on the active thumb
    /// clears it.
    private func reactionButton(_ reaction: AICoachReaction) -> some View {
        let isActive = workout.aiCoachReaction == reaction
        return Button {
            withAnimation(AppAnimation.snappy) {
                workout.aiCoachReaction = isActive ? nil : reaction
            }
            context.saveOrLog("the coach-insight reaction")
        } label: {
            Image(systemName: reaction == .up ? "hand.thumbsup" : "hand.thumbsdown")
                .font(.dsHeadline)
                .foregroundStyle(isActive ? Color.brand : Color.secondary)
                .frame(width: 48, height: 48)
                .strideCard(cornerRadius: AppRadius.md)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reaction == .up ? "Helpful" : "Not helpful")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private func aiAttribution(_ insight: AICoachInsight) -> some View {
        HStack(spacing: 5) {
            SparkleShape()
                .fill(Color.success)
                .frame(width: 11, height: 11)
            Text("Generated by \(appSettings.aiProvider.localizedName) · \(workout.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                .font(.dsCaption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.xxs)
    }

    private var aiEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hasAIKey ? "Ready for analysis" : "AI Coach is off")
                .font(.dsSubhead.weight(.bold))
            Text(hasAIKey
                 ? "Tap Load to fetch on-device AI coaching feedback for this workout."
                 : "Turn on AI Coach in Settings to load on-device workout analysis.")
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.md)
    }

    private func aiUnavailableCard(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(markdownText(insight.headline))
                .font(.dsSubhead.weight(.bold))
            Text(markdownText(insight.summary))
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.md)
    }
}
