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
                Text("Coaching read")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.small)
            }
            CoachText(aiStreamBuffer)
                .font(.dsSubhead)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .strideCard(cornerRadius: AppRadius.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Coach analysis, still writing")
    }

    /// Placeholder in the shape of the page: the verdict card, then the flat sections.
    var aiCoachSkeletonSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            VStack(alignment: .leading, spacing: 10) {
                AIInsightSkeletonShape().frame(maxWidth: 240, minHeight: 24, maxHeight: 24)
                AIInsightSkeletonShape().frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                AIInsightSkeletonShape().frame(maxWidth: 220, minHeight: 14, maxHeight: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.lg)
            .strideCard()

            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    AIInsightSkeletonShape().frame(width: 90, height: 11)
                    AIInsightSkeletonShape().frame(maxWidth: 260, minHeight: 14, maxHeight: 14)
                    AIInsightSkeletonShape().frame(maxWidth: .infinity, minHeight: 11, maxHeight: 11)
                }
                .padding(.horizontal, AppSpacing.xs)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coach analysis, starting")
    }

    private struct AIInsightSkeletonShape: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var opacity: Double = 0.12

        var body: some View {
            RoundedRectangle(cornerRadius: AppRadius.micro)
                .fill(Color.secondary.opacity(reduceMotion ? 0.2 : opacity))
                .onAppear {
                    // A steady placeholder under Reduce Motion; the pulse is motion.
                    guard !reduceMotion else { return }
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
        // The request below reads the rating as it stands now, so the "refresh to include
        // it" hint under the feel card is answered from here on.
        feelChangedSinceInsight = false
        let result = await container.aiCoachService.evaluateWithProvider(
            workout: workout,
            recentHistory: historySlice,
            profile: profiles.first,
            provider: appSettings.aiProvider,
            heartRateZones: zoneSlices,
            unitPreference: appSettings.unitPreference,
            onPartialText: { text in
                // Direct assignment on the main actor; see `OnDeviceCoachGenerating` for
                // why this is not wrapped in a `Task`.
                aiStreamBuffer = text
            }
        )
        aiInsight = result
        if result.apiReady {
            workout.cachedAIInsight = result
            context.saveOrLog("the cached coach insight")
        }
    }

    /// Starts the coach's read the first time a run without one is opened, so the
    /// runner never has to ask for it. Once a read succeeds it is cached on the run,
    /// and this does nothing on later opens.
    ///
    /// An unstructured task on purpose: opening the coach page replaces the summary in
    /// place, and a `.task` on the summary would cancel the read mid-stream.
    func startCoachReadIfNeeded() {
        guard appSettings.aiInsightsEnabled,
              hasAIKey,
              aiInsight == nil,
              workout.cachedAIInsight == nil,
              !isLoadingAIInsight else { return }
        Task { await loadAIInsight() }
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
    func nextWorkoutForFeedback() -> ScheduledWorkout? {
        let completedDate = matchedScheduled?.scheduledDate
            ?? workout.scheduledWorkout?.scheduledDate
            ?? workout.date

        return AdaptableWorkoutSelector.nextAdaptableWorkout(
            in: planForNextSessionUpdate,
            after: completedDate
        )
    }


    func workoutLabel(_ workout: ScheduledWorkout) -> String {
        let date = workout.scheduledDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(date) \(workout.workoutType.localizedName)"
    }

    var hasAIKey: Bool {
        // Apple's on-device / Private Cloud Compute models need no key.
        appSettings.hasAICredentials
    }

    var postRunCoachPrompts: [String] {
        [
            "Why was my HR so high?",
            "Should I rest tomorrow?",
            "How does this compare to last week?"
        ]
    }
}
