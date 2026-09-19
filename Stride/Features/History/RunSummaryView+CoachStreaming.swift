import SwiftUI
import SwiftData

// Part of `RunSummaryView` (D1).
// Generating the coach's read: the skeleton and streaming preview shown while it is
// being produced, the request itself, and applying its next-session feedback to the plan.

extension RunSummaryView {

    // MARK: Skeleton loading

    /// The partial coaching text as it streams in.
    ///
    /// `aiStreamBuffer` was accumulated and never rendered (N22), so the runner watched a
    /// shimmering skeleton while the analysis was already in memory. The full card still
    /// replaces this once the structured insight is decoded.
    var aiStreamingPreviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SparkleShape()
                    .fill(Color.brand)
                    .frame(width: 14, height: 14)
                Text("COACHING READ")
                    .font(.dsCaption2.weight(.bold))
                    .kerning(1.4)
                    .foregroundStyle(.brand)
                Spacer()
                ProgressView().controlSize(.small)
            }
            CoachText(aiStreamBuffer)
                .font(.dsSubhead)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Coach analysis, still writing")
    }

    var aiCoachSkeletonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Headline capsule skeleton
            AIInsightSkeletonShape()
                .frame(width: 180, height: 32)
                .clipShape(Capsule())

            // Key Takeaway skeleton
            VStack(alignment: .leading, spacing: 8) {
                AIInsightSkeletonShape().frame(width: 110, height: 11)
                AIInsightSkeletonShape().frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                AIInsightSkeletonShape().frame(maxWidth: 260, minHeight: 14, maxHeight: 14)
            }
            .padding()
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))

            // Action Plan skeleton
            VStack(alignment: .leading, spacing: 8) {
                AIInsightSkeletonShape().frame(width: 90, height: 11)
                ForEach(0..<3, id: \.self) { _ in
                    HStack(alignment: .top, spacing: 10) {
                        AIInsightSkeletonShape().frame(width: 14, height: 14).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 6) {
                            AIInsightSkeletonShape().frame(width: 140, height: 12)
                            AIInsightSkeletonShape().frame(maxWidth: .infinity, minHeight: 11, maxHeight: 11)
                        }
                    }
                    .padding(10)
                    .background(.surfaceTertiary, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                }
            }

            // Next Session skeleton
            VStack(alignment: .leading, spacing: 6) {
                AIInsightSkeletonShape().frame(width: 90, height: 11)
                AIInsightSkeletonShape().frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                AIInsightSkeletonShape().frame(maxWidth: 200, minHeight: 11, maxHeight: 11)
            }
            .padding()
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }

    private struct AIInsightSkeletonShape: View {
        @State private var opacity: Double = 0.12

        var body: some View {
            RoundedRectangle(cornerRadius: AppRadius.micro)
                .fill(Color.secondary.opacity(opacity))
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        opacity = 0.28
                    }
                }
        }
    }

    // Both of these used to be spelled out here and again inside each nested row type;
    // `CoachMarkdown` is now the one definition (N27).
    func normalizedMarkdownText(_ text: String) -> String {
        CoachMarkdown.stripped(text)
    }

    func markdownText(_ text: String) -> AttributedString {
        CoachMarkdown.attributed(text)
    }

    @MainActor
    func loadAIInsight() async {
        guard !isLoadingAIInsight else { return }
        guard hasAIKey else {
            aiInsight = nil
            return
        }
        isLoadingAIInsight = true
        aiStreamBuffer = ""
        defer {
            isLoadingAIInsight = false
            aiStreamBuffer = ""
        }

        // The coach cites the zone breakdown, so make sure it exists before asking. Normally
        // the on-open task has already filled it; this covers a tap that lands first, and a
        // run whose heart-rate samples still need the HealthKit backfill.
        if zoneSlices.isEmpty {
            await loadHeartRateZones()
        }

        let historySlice = Array(recentHistory.prefix(Self.insightHistoryRunCount))
        let result = await container.aiCoachService.evaluateWithProvider(
            workout: workout,
            recentHistory: historySlice,
            profile: profiles.first,
            provider: appSettings.aiProvider,
            heartRateZones: zoneSlices,
            unitPreference: appSettings.unitPreference,
            onPartialText: { text in
                Task { @MainActor in
                    setInsightStreamText(text)
                }
            }
        )
        aiInsight = result
        if result.apiReady {
            workout.cachedAIInsight = result
            context.saveOrLog("the cached coach insight")
        }
    }

    var canApplyNextSessionFeedback: Bool {
        hasAIKey && profiles.first != nil && nextWorkoutForFeedback() != nil
    }

    @MainActor
    func applyNextSessionFeedback(_ insight: AICoachInsight) async {
        guard !isApplyingNextSessionFeedback else { return }
        guard hasAIKey else {
            nextSessionUpdateMessage = "Turn on AI Coach in Settings to update the plan."
            return
        }
        guard let profile = profiles.first else {
            nextSessionUpdateMessage = "Create a runner profile before updating planned workouts."
            return
        }
        guard let nextWorkout = nextWorkoutForFeedback() else {
            nextSessionUpdateMessage = "No upcoming planned run is available to update."
            return
        }

        isApplyingNextSessionFeedback = true
        nextSessionUpdateMessage = "Updating \(workoutLabel(nextWorkout))..."
        defer { isApplyingNextSessionFeedback = false }

        guard let adapted = await container.aiCoachService.adaptScheduledWorkoutWithProvider(
            scheduled: nextWorkout,
            recentHistory: Array(recentRuns.prefix(Self.adaptationHistoryRunCount)),
            profile: profile,
            provider: appSettings.aiProvider,
            unitPreference: appSettings.unitPreference,
            coachFeedback: CoachInsightText.feedbackPrompt(
                insight: insight,
                completedType: displayType,
                completedOn: workout.date
            )
        ) else {
            nextSessionUpdateMessage = "The coach feedback could not be applied. Try refreshing the AI analysis."
            return
        }

        // Applying coach feedback edits the next session in place; it no longer prunes
        // "duplicate" future runs afterwards (N29). That pruner cleaned up phantom
        // workouts a removed code path used to insert, and with the producer gone the
        // only thing it could still delete was a real scheduled run.
        nextWorkout.applyAdaptation(from: adapted)
        context.saveOrLog("the coach-adapted next session")

        if let plan = nextWorkout.week?.plan {
            try? await container.healthKitRepository.removeWorkoutPlans(for: plan)
            try? await container.healthKitRepository.syncWorkoutPlans(for: plan, unitPreference: appSettings.unitPreference)
        }

        nextSessionUpdateMessage = "Updated \(workoutLabel(nextWorkout)) in your plan."
    }

    /// The soonest planned run the coach's feedback can be applied to.
    ///
    /// Bounded below by the session this run fulfilled, so feedback on Tuesday's tempo
    /// never rewrites Tuesday's tempo. Everything else — run types only, never the race,
    /// nothing completed, nothing in the past — is the shared rule (D1).
    private func nextWorkoutForFeedback() -> ScheduledWorkout? {
        let completedDate = matchedScheduled?.scheduledDate
            ?? workout.scheduledWorkout?.scheduledDate
            ?? workout.date

        return AdaptableWorkoutSelector.nextAdaptableWorkout(
            in: planForNextSessionUpdate,
            after: completedDate
        )
    }


    private func workoutLabel(_ workout: ScheduledWorkout) -> String {
        let date = workout.scheduledDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(date) \(workout.workoutType.localizedName)"
    }

    /// The coach's summary as written so far, which replaces what was shown before.
    ///
    /// This used to append, back when the backend emitted the finished summary once and
    /// "the chunk" and "the whole text" were the same string. Streaming partials are
    /// cumulative snapshots (see `OnDeviceCoachGenerating`), so appending them would
    /// render the summary once per token.
    @MainActor
    private func setInsightStreamText(_ text: String) {
        aiStreamBuffer = text
    }

    var hasAIKey: Bool {
        // Apple's on-device / Private Cloud Compute models need no key.
        appSettings.hasAICredentials
    }

    var postRunCoachPrompts: [String] {
        [
            "Why was my HR so high?",
            "Should I rest tomorrow?",
            "How does this compare to last week?",
            "Adjust this week"
        ]
    }
}
