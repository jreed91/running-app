import SwiftUI
import SwiftData

// Part of `RunSummaryView` (D1).
// The coach page, opened from the run screen's coach card (`+CoachSummary`). It reads as
// a verdict: one card with what the run meant, then the one thing to do next, the next
// session, and asking the coach, on the page itself rather than a stack of cards.

extension RunSummaryView {

    // MARK: AI coach section

    @ViewBuilder
    var aiCoachSection: some View {
        if appSettings.aiInsightsEnabled {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
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
                        aiVerdictCard(aiInsight)
                        aiActionPlan(aiInsight)
                        aiNextSession(aiInsight)
                        aiAskCoach
                        aiFullAnalysis(aiInsight)
                        aiFooter
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

    /// A section label on the page ground, aligned with the text inside the cards above.
    private func coachSectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .strideEyebrow()
            .foregroundStyle(.secondary)
    }

    // MARK: Verdict

    /// The only card on the page: the headline, the coach's summary sentence, and at most
    /// three facts behind it. The model's confidence score is not shown; it is the model
    /// grading itself, and a runner cannot act on it.
    private func aiVerdictCard(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(markdownText(insight.headline))
                .font(.dsTitle2.weight(.heavy))
                .kerning(-0.55)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)

            let summary = insight.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                Text(markdownText(summary))
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let evidence = Array(insight.evidence.prefix(Self.coachEvidenceLimit))
            if !evidence.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(evidence, id: \.self) { item in
                        evidenceStat(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .strideCard()
    }

    /// How many evidence facts the verdict shows; more read as a wall of chips.
    static let coachEvidenceLimit = 3

    /// One fact behind the verdict: the value large, what it is under it, and the change
    /// against the plan or the usual when there is one. Equal-width cells, one line each,
    /// so a long label shrinks instead of breaking mid-word ("Dis-tance").
    private func evidenceStat(_ item: AICoachEvidenceItem) -> some View {
        let value = normalizedMarkdownText(item.value)
        let delta = item.delta.map(normalizedMarkdownText)
        return VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.dsHeadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(normalizedMarkdownText(item.label))
                .font(.dsCaption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if CoachInsightText.deltaAddsInformation(value: value, delta: delta), let delta {
                Text(delta)
                    .font(.dsCaption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(aiTone(item.tone))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, AppSpacing.sm)
        .background(.surfaceTertiary, in: RoundedRectangle(cornerRadius: AppRadius.sm))
        .accessibilityElement(children: .combine)
    }

    // MARK: Do this next

    /// The coach's first action leads; the rest are plain lines under it.
    @ViewBuilder
    private func aiActionPlan(_ insight: AICoachInsight) -> some View {
        let actions = Array(insight.actionItems.prefix(3))
        if let lead = actions.first {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                coachSectionLabel("Do this next")

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(markdownText(lead.title))
                            .font(.dsHeadline.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        if let metric = lead.metric.map(normalizedMarkdownText), !metric.isEmpty {
                            Text(metric)
                                .font(.dsCaption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Color.brandText)
                                .lineLimit(1)
                        }
                    }
                    Text(markdownText(lead.detail))
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(actions.dropFirst().enumerated()), id: \.offset) { _, action in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(markdownText(action.title))
                                .font(.dsFootnote.weight(.semibold))
                                .foregroundStyle(.primary)
                            // The title alone ("Prioritize recovery") gave no reason.
                            Text(markdownText(action.detail))
                                .font(.dsFootnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.xs)
        }
    }

    // MARK: Next session

    /// The coach's suggestion, and a button that names the planned workout it rewrites.
    /// Tapping the whole card used to rewrite the plan with nothing on it saying so.
    private func aiNextSession(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            coachSectionLabel("Next session")

            VStack(alignment: .leading, spacing: 2) {
                Text(markdownText(insight.nextWorkoutSuggestion))
                    .font(.dsSubhead.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if let rationale = insight.nextWorkoutRationale?.trimmingCharacters(in: .whitespacesAndNewlines), !rationale.isEmpty {
                    Text(markdownText(rationale))
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if hasAIKey, profiles.first != nil, let target = nextWorkoutForFeedback(),
               target.id != updatedNextSessionID {
                Button {
                    Task { await applyNextSessionFeedback(insight) }
                } label: {
                    HStack(spacing: 6) {
                        if isApplyingNextSessionFeedback {
                            ProgressView().controlSize(.small)
                        }
                        Text("Update \(workoutLabel(target))")
                    }
                }
                .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
                .disabled(isApplyingNextSessionFeedback)
                .accessibilityHint(
                    String(
                        localized: "Rewrites that planned run using this analysis",
                        comment: "Hint on the coach's update-next-session button"
                    )
                )
            }

            if let nextSessionUpdateMessage {
                Text(nextSessionUpdateMessage)
                    .font(.dsCaption.weight(.medium))
                    .foregroundStyle(nextSessionUpdateMessage.hasPrefix("Updated") ? Color.success : Color.secondary)
            }
        }
        .padding(.horizontal, AppSpacing.xs)
    }

    // MARK: Ask the coach

    private var aiAskCoach: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            coachSectionLabel("Ask your coach")
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
                    Text("Ask about this run…")
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
    }

    // MARK: Full analysis

    private func aiFullAnalysis(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Button {
                showFullAIAnalysis.toggle()
            } label: {
                HStack {
                    Text(showFullAIAnalysis ? "Hide the full analysis" : "Read the full analysis")
                        .font(.dsFootnote.weight(.semibold))
                        .foregroundStyle(Color.brandText)
                    Spacer()
                    StrideIcon(name: .chevronRight, size: 12, color: .secondary, strokeWeight: 2.4)
                        .rotationEffect(.degrees(showFullAIAnalysis ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showFullAIAnalysis {
                CoachText(CoachInsightText.fullAnalysis(for: insight))
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, AppSpacing.xs)
        .adaptiveAnimation(AppAnimation.snappy, value: showFullAIAnalysis)
    }

    // MARK: Footer

    /// Who wrote the read, whether it helped, and a quiet way to write it again.
    private var aiFooter: some View {
        HStack(spacing: 4) {
            SparkleShape()
                .fill(Color.secondary)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text("Written by Apple Intelligence")
                .font(.dsCaption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            reactionButton(.up)
            reactionButton(.down)
            rewriteButton
        }
        .padding(.horizontal, AppSpacing.xs)
    }

    private var rewriteButton: some View {
        Button {
            Task { await loadAIInsight() }
        } label: {
            Text("Rewrite")
        }
        .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
        .disabled(isLoadingAIInsight || !hasAIKey)
        .accessibilityHint(
            String(localized: "Writes a new analysis of this run", comment: "Hint on the coach's Rewrite button")
        )
    }

    /// Thumbs-up/down on the coach insight, stored on the run (N22).
    ///
    /// The rating used to live in view state that nothing read — not persisted, not sent
    /// anywhere, gone on dismiss. It now survives, and a second tap on the active thumb
    /// clears it.
    private func reactionButton(_ reaction: AICoachReaction) -> some View {
        let isActive = workout.aiCoachReaction == reaction
        return Button {
            workout.aiCoachReaction = isActive ? nil : reaction
            context.saveOrLog("the coach-insight reaction")
        } label: {
            Image(systemName: reaction == .up
                  ? (isActive ? "hand.thumbsup.fill" : "hand.thumbsup")
                  : (isActive ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.dsSubhead)
                .foregroundStyle(isActive ? Color.brand : Color.secondary)
                .adaptiveAnimation(AppAnimation.snappy, value: isActive)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reaction == .up ? "Helpful" : "Not helpful")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Empty and unavailable

    /// No read yet. The read starts by itself when the run opens (`startCoachReadIfNeeded`),
    /// so this mostly shows when AI Coach is off.
    private var aiEmptyState: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(hasAIKey ? "No analysis yet" : "AI Coach is off")
                .font(.dsSubhead.weight(.bold))
            Text(hasAIKey
                 ? "Get a coaching read of this run."
                 : "Turn on AI Coach in Settings to get a coaching read of this run.")
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
            if hasAIKey {
                Button {
                    Task { await loadAIInsight() }
                } label: {
                    Text("Write analysis")
                }
                .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .strideCard()
    }

    private func aiUnavailableCard(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(markdownText(insight.headline))
                .font(.dsSubhead.weight(.bold))
            Text(markdownText(insight.summary))
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            rewriteButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .strideCard()
    }
}
