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
                            Text("AI COACH")
                                .font(.dsCaption2.weight(.bold))
                                .kerning(1.4)
                                .foregroundStyle(.brand)
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
                                .fill(.onFill)
                                .frame(width: 11, height: 11)
                            Text(aiInsight == nil ? "Load" : "Refresh")
                                .font(.dsCaption.weight(.bold))
                        }
                        .foregroundStyle(.onFill)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.brand, in: Capsule())
                        .appGlow(.standard, color: .brand)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingAIInsight || !hasAIKey)
                }
                .padding(.horizontal, 4)

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
            .padding(.top, 8)
        }
    }

    private func aiCoachingReadCard(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SparkleShape()
                    .fill(Color.brand)
                    .frame(width: 14, height: 14)
                Text("COACHING READ")
                    .font(.dsCaption2.weight(.bold))
                    .kerning(1.4)
                    .foregroundStyle(.brand)
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
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.warning.opacity(0.14), Color.warning.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppRadius.lg)
        )
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).strokeBorder(Color.warning.opacity(0.28), lineWidth: 0.5))
    }

    private var aiAskCoachCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ASK COACH")
                .font(.dsCaption2.weight(.bold))
                .kerning(1.4)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(postRunCoachPrompts, id: \.self) { prompt in
                        Button {
                            coachChatRequest = AICoachChatRequest(prompt: prompt)
                        } label: {
                            Text(prompt)
                                .font(.dsCaption.weight(.semibold))
                                .foregroundStyle(.brand)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.surfaceSecondary, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.brand.opacity(0.22), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
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
                        .background(Color.brand, in: Circle())
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(.surfaceSecondary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private func aiActionPlan(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DO THIS NEXT")
                .font(.dsCaption2.weight(.bold))
                .kerning(1.4)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

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
                        RoundedRectangle(cornerRadius: AppRadius.md)
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
                        Text("NEXT SESSION")
                            .font(.dsCaption2.weight(.bold))
                            .kerning(0.8)
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
                    .padding(.horizontal, 2)
            }
        }
        .padding(14)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
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
                        .font(.dsSubhead.weight(.semibold))
                        .foregroundStyle(.brand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .buttonStyle(.plain)

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
            Text("FULL ANALYSIS")
                .font(.dsCaption2.weight(.bold))
                .kerning(1.1)
                .foregroundStyle(.secondary)

            Text(markdownText(CoachInsightText.fullAnalysis(for: insight)))
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
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
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
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
        .padding(.top, 2)
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
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
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
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}
