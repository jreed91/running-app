import SwiftUI
import SwiftData

struct AICoachChatView: View {
    private let workoutContext: RunWorkout?
    private let initialPrompt: String?

    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How many recent runs the coach prompt summarises. Also the fetch limit below —
    /// the prompt is the only consumer of more than the newest run.
    private static let promptRunCount = 8

    /// Newest runs only. This used to fetch the entire runs table on every open of the
    /// chat, for a prompt that reads eight of them (D6).
    ///
    /// Nothing here needs a true total: the header's "Runs" count is only rendered when
    /// there is no latest run at all, which means this fetch came back empty.
    static var recentRunsDescriptor: FetchDescriptor<RunWorkout> {
        // Runs only (N38): the coach is being asked about training, and a walk taking one
        // of the eight prompt slots costs the model a run it would otherwise have read.
        RunWorkout.runsOnlyDescriptor(
            sortBy: [SortDescriptor(\RunWorkout.date, order: .reverse)],
            fetchLimit: promptRunCount
        )
    }

    @Query(AICoachChatView.recentRunsDescriptor)
    private var recentRuns: [RunWorkout]

    @Query(
        filter: #Predicate<TrainingPlan> { $0.isActive },
        sort: \TrainingPlan.createdAt, order: .reverse
    )
    private var activePlans: [TrainingPlan]

    @State private var messages: [AICoachChatMessage] = []
    @State private var draft = ""
    @State private var isWaitingForCoach = false
    /// The coach's reply as it is written, shown in a live bubble until the finished
    /// message is appended to `messages`. Empty while the model has produced nothing yet,
    /// which is the only stretch the typing dots still cover.
    @State private var streamingReply = ""
    @State private var didSendInitialPrompt = false
    /// This morning's readiness (B7), so "should I rest tomorrow?" is answered from the
    /// runner's HRV, resting heart rate and sleep, not only from their run log. `nil`
    /// until the Health read returns, and when there is nothing in Health to score.
    @State private var readiness: RecoveryReadiness?
    @FocusState private var isComposerFocused: Bool

    init(workout: RunWorkout? = nil, initialPrompt: String? = nil) {
        self.workoutContext = workout
        self.initialPrompt = initialPrompt
    }

    private var latestRun: RunWorkout? { workoutContext ?? recentRuns.first }
    private var activePlan: TrainingPlan? { activePlans.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        contextHeader
                        ForEach(messages) { message in
                            messageRow(message)
                        }
                        if isWaitingForCoach {
                            if streamingReply.isEmpty {
                                typingRow
                            } else {
                                streamingReplyRow
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
                }
                .scrollDismissesKeyboard(.interactively)
                // A transcript follows its newest line, and that is a property of the
                // scroll view rather than an event to react to. This replaces a
                // `ScrollViewReader` and two `onChange` handlers that chased it by hand
                // (U7) — and chased it a step behind, because they fired on the *counts*
                // changing, so a long reply that grew the last bubble after it was
                // appended, or a keyboard that shrank the container, moved the bottom of
                // the transcript out of view with nothing left to trigger a correction.
                // The anchor covers all three, since each one is a size change.
                //
                // `initialOffset` is deliberately left alone: the top of the context
                // header is still what opens, because on a fresh chat it is the only
                // thing there is to read.
                .defaultScrollAnchor(.bottom, for: .sizeChanges)

                quickReplies
                composer
            }
            .background(Color.surfacePrimary)
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "sparkles")
                        .font(.dsSubhead.weight(.bold))
                        .foregroundStyle(.brand)
                        // On-device generation can take a few seconds with no other sign
                        // that anything is happening; the glyph that represents the coach
                        // is the natural place to say "thinking".
                        .symbolEffect(.variableColor.iterative, isActive: isWaitingForCoach)
                        .frame(width: 36, height: 36)
                        .background(.surfaceSecondary, in: Circle())
                        // Decoration, not a control — it reads as "sparkles" otherwise.
                        .accessibilityHidden(true)
                }
            }
            .task {
                // Read first so the opening reply already has it.
                await loadReadiness()
                await sendInitialPromptIfNeeded()
            }
        }
    }

    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                coachAvatar(size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI COACH")
                        .font(.dsCaption2.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)
                    Text(contextSubtitle)
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                readinessBadge
            }

            Text("Ask follow-ups about your last run, training plan, recovery, or pacing. Stride keeps the answers grounded in your recent data.")
                .font(.dsSubhead)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }

    private var readinessBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(appSettings.aiInsightsEnabled && hasAIKey ? Color.success : Color.warning)
                .frame(width: 6, height: 6)
            Text(appSettings.aiInsightsEnabled && hasAIKey ? "READY" : "SETUP")
                .font(.dsCaption2.weight(.bold))
                .tracking(0.7)
        }
        .foregroundStyle(appSettings.aiInsightsEnabled && hasAIKey ? Color.success : Color.warning)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            (appSettings.aiInsightsEnabled && hasAIKey ? Color.success : Color.warning).opacity(0.14),
            in: Capsule()
        )
    }

    private var quickReplies: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickReplyPrompts, id: \.self) { prompt in
                    Button {
                        Task { await send(prompt) }
                    } label: {
                        Text(prompt)
                            .foregroundStyle(.brandText)
                    }
                    .buttonStyle(.strideChip())
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.sm)
        }
        .background(Color.surfacePrimary)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.dsSubhead.weight(.bold))
                .foregroundStyle(.brand)

            TextField("Ask your coach...", text: $draft, axis: .vertical)
                .font(.dsSubhead)
                .lineLimit(1...4)
                .focused($isComposerFocused)
                .submitLabel(.send)
                .onSubmit {
                    Task { await send(draft) }
                }

            Button {
                Task { await send(draft) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.dsSubhead.weight(.bold))
                    .foregroundStyle(canSendDraft ? Color.onFill : Color.secondary)
                    .frame(width: 32, height: 32)
                    .background {
                        if canSendDraft {
                            Circle().fill(.route)
                        } else {
                            Circle().fill(.surfaceTertiary)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(!canSendDraft || isWaitingForCoach)
            .accessibilityLabel("Send message")
        }
        .padding(.leading, AppSpacing.lg)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(.surfaceSecondary, in: Capsule())
        .overlay(Capsule().strokeBorder(.cardStroke, lineWidth: 1))
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, AppSpacing.md)
        .background(Color.surfacePrimary)
    }

    private func messageRow(_ message: AICoachChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if message.sender == .coach {
                coachAvatar(size: 36)
            } else {
                Spacer(minLength: 44)
            }

            VStack(alignment: message.sender == .coach ? .leading : .trailing, spacing: 8) {
                if message.sender == .coach {
                    coachBubbleHeader(message)
                }

                // `CoachText`, not `Text`: a reply with a list in it is a list, and
                // the single-`Text` version showed every marker after the first line
                // as a literal `- ` in the middle of a sentence (see `CoachMarkdown`).
                CoachText(message.text)
                    .font(.dsSubhead)
                    .lineSpacing(3)
                    .foregroundStyle(.primary)

                if !message.metrics.isEmpty {
                    metricGrid(message.metrics)
                }

                // The setup and fallback replies both send the runner to Settings; take
                // them there rather than leaving them to find the tab.
                if message.sender == .coach, message.status == .setupNeeded {
                    Button("Open Settings") { openCoachSettings() }
                        .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
                }
            }
            .padding(14)
            .background {
                if message.sender == .coach {
                    bubbleShape(for: message).fill(.surfaceSecondary)
                        .overlay(bubbleShape(for: message).strokeBorder(.cardStroke, lineWidth: 1))
                } else {
                    // A brand tint, not the route: the route means progress or go, and
                    // the runner's own words are neither.
                    bubbleShape(for: message).fill(Color.brand.opacity(0.14))
                        .overlay(bubbleShape(for: message).strokeBorder(Color.brand.opacity(0.22), lineWidth: 1))
                }
            }
            .frame(maxWidth: 310, alignment: message.sender == .coach ? .leading : .trailing)

            if message.sender == .coach {
                Spacer(minLength: 20)
            }
        }
    }

    /// The coach's bubble while the reply is still being written.
    ///
    /// Built from `messageRow` rather than duplicating the bubble: the live text and the
    /// finished message are the same thing at two moments, so when the reply lands the
    /// bubble does not visibly change shape, position or typography — the text simply
    /// stops growing. The metrics and status badge are left off here and applied when the
    /// message is appended, because whether this is the opening reply is not known until
    /// it is.
    private var streamingReplyRow: some View {
        messageRow(
            AICoachChatMessage(
                sender: .coach,
                text: streamingReply,
                metrics: [],
                status: nil
            )
        )
    }

    private var typingRow: some View {
        HStack(alignment: .top, spacing: 10) {
            coachAvatar(size: 36)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: 6, height: 6)
                        .opacity(isWaitingForCoach ? 1 : 0.3)
                        // A looping pulse is exactly what Reduce Motion asks to stop.
                        .animation(
                            reduceMotion
                                ? nil
                                : Animation.easeInOut(duration: 0.7)
                                    .repeatForever()
                                    .delay(Double(index) * 0.12),
                            value: isWaitingForCoach
                        )
                }
            }
            .padding(14)
            .background(
                .surfaceSecondary,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: AppRadius.micro,
                    bottomLeadingRadius: AppRadius.lg,
                    bottomTrailingRadius: AppRadius.lg,
                    topTrailingRadius: AppRadius.lg
                )
            )
            Spacer(minLength: 20)
        }
    }

    private func coachBubbleHeader(_ message: AICoachChatMessage) -> some View {
        HStack(spacing: 6) {
            Text("Coach")
                .font(.dsFootnote.weight(.bold))
            if let status = message.status {
                HStack(spacing: 5) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 5, height: 5)
                    Text(status.title)
                        .font(.dsCaption2.weight(.bold))
                        .tracking(0.4)
                }
                .foregroundStyle(status.color)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, 3)
                .background(status.color.opacity(0.14), in: Capsule())
            }
        }
    }

    private func metricGrid(_ metrics: [AICoachMiniMetric]) -> some View {
        HStack(spacing: 6) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.label.uppercased())
                        .font(.dsCaption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(metric.value)
                            .font(.dsSubhead.weight(.bold).monospacedDigit())
                        if let delta = metric.delta {
                            Text(delta)
                                .font(.dsCaption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(metric.tone)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.surfaceTertiary, in: RoundedRectangle(cornerRadius: AppRadius.sm))
            }
        }
    }

    private func coachAvatar(size: CGFloat) -> some View {
        // A brand-tinted disc, not the route: an avatar is decoration, and the route
        // means progress or go.
        ZStack {
            Circle().fill(Color.brand.opacity(0.12))
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.brandText)
        }
        .frame(width: size, height: size)
    }

    private func bubbleShape(for message: AICoachChatMessage) -> some InsettableShape {
        UnevenRoundedRectangle(
            topLeadingRadius: message.sender == .coach ? AppRadius.micro : AppRadius.lg,
            bottomLeadingRadius: AppRadius.lg,
            bottomTrailingRadius: message.sender == .coach ? AppRadius.lg : AppRadius.micro,
            topTrailingRadius: AppRadius.lg
        )
    }

    /// Closes the chat and switches to the Settings tab, where the AI Coach toggle and
    /// model picker live.
    private func openCoachSettings() {
        container.appNavigation.select(.settings)
        // The chat can sit on the post-run review sheet; close that too, or Settings opens
        // underneath it.
        container.pendingReviewWorkout = nil
        dismiss()
    }

    @MainActor
    private func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWaitingForCoach else { return }

        withAnimation(AppAnimation.snappy) {
            messages.append(
                AICoachChatMessage(
                    sender: .runner,
                    text: trimmed,
                    metrics: [],
                    status: nil
                )
            )
        }
        draft = ""

        guard appSettings.aiInsightsEnabled, hasAIKey else {
            let setupText = "Turn on AI Coach in Settings to chat with \(appSettings.aiProvider.localizedName)."
            messages.append(
                AICoachChatMessage(
                    sender: .coach,
                    text: setupText,
                    metrics: [],
                    status: .setupNeeded
                )
            )
            return
        }

        isWaitingForCoach = true
        streamingReply = ""
        defer {
            isWaitingForCoach = false
            streamingReply = ""
        }

        // The metric chips and status badge summarize the run the conversation
        // opened on. They belong to the first coach reply only — repeating them on
        // every answer implies each reply is freshly grounded in that same data.
        let isOpeningReply = !messages.contains { $0.sender == .coach }

        do {
            let reply = try await container.aiCoachService.chatWithProvider(
                provider: appSettings.aiProvider,
                context: coachContext,
                messages: providerMessages,
                onPartialText: { text in
                    // Assigned directly: the closure is `@MainActor` and the backend
                    // awaits it, so this is a step of the stream rather than a task
                    // racing it.
                    streamingReply = text
                }
            )
            withAnimation(AppAnimation.snappy) {
                messages.append(
                    AICoachChatMessage(
                        sender: .coach,
                        text: reply,
                        metrics: isOpeningReply ? openingMetrics : [],
                        status: isOpeningReply ? openingStatus : nil
                    )
                )
            }
        } catch {
            withAnimation(AppAnimation.snappy) {
                messages.append(
                    AICoachChatMessage(
                        sender: .coach,
                        text: Self.failureText(for: error, provider: appSettings.aiProvider),
                        metrics: [],
                        status: .setupNeeded
                    )
                )
            }
        }
    }

    /// Hitting the daily Private Cloud Compute allowance is not a setup problem, and
    /// telling a runner to go and enable Apple Intelligence — which is already on — sends
    /// them somewhere that cannot help. Name the real cause and, when the framework knows
    /// it, when the allowance comes back.
    private static func failureText(for error: any Error, provider: AIProvider) -> String {
        if let coachError = error as? OnDeviceCoachError,
           case .serverQuotaExceeded(let resetDate) = coachError {
            guard let resetDate else {
                return "You have used today's Private Cloud Compute requests. They refresh daily — or switch to the on-device model in Settings to keep going now."
            }
            let refresh = resetDate.formatted(date: .omitted, time: .shortened)
            return "You have used today's Private Cloud Compute requests. They refresh at \(refresh) — or switch to the on-device model in Settings to keep going now."
        }
        return "I could not reach \(provider.localizedName). Make sure Apple Intelligence is enabled on this device, then try again."
    }

    @MainActor
    private func sendInitialPromptIfNeeded() async {
        guard !didSendInitialPrompt else { return }
        didSendInitialPrompt = true
        guard let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            return
        }
        await send(prompt)
    }

    private var canSendDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var providerMessages: [AIProviderChatMessage] {
        messages.map { message in
            AIProviderChatMessage(
                role: message.sender == .coach ? "assistant" : "user",
                content: message.text
            )
        }
    }

    private var hasAIKey: Bool {
        // Apple's on-device / Private Cloud Compute models need no key.
        appSettings.hasAICredentials
    }

    private var contextSubtitle: String {
        if let latestRun {
            "After \(latestRun.workoutType.localizedName.lowercased()) run"
        } else if let activePlan {
            "\(activePlan.targetRace.localizedName) plan context"
        } else {
            "Plan and workout context"
        }
    }

    private var quickReplyPrompts: [String] {
        [
            "Adjust this week",
            "Why was effort high?",
            "Show last 5 easy runs",
            "Should I rest tomorrow?"
        ]
    }

    /// Reads last night's recovery from Health and scores it against four weeks of runs.
    ///
    /// Its own fetch rather than `recentRuns`: the load component compares seven days to
    /// twenty-eight, and the eight runs the prompt lists would make an ordinary week look
    /// like a spike.
    private func loadReadiness() async {
        let now = Date()
        let readings = await container.healthKitRepository.fetchRecoveryReadings(
            endingAt: now,
            baselineDays: RecoveryReadiness.baselineDays
        )
        guard !readings.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-Double(RecoveryReadiness.baselineDays) * 86_400)
        let descriptor = FetchDescriptor<RunWorkout>(predicate: #Predicate { $0.date > cutoff })
        let runs = (try? modelContext.fetch(descriptor)) ?? []
        readiness = RecoveryReadiness.evaluate(readings: readings, runs: runs, now: now)
    }

    private var coachContext: String {
        let unit = appSettings.unitPreference
        let selectedRun = latestRun.map { run in
            """
            Current workout context:
            Date: \(run.date.formatted(date: .abbreviated, time: .shortened))
            Type: \(run.workoutType.displayName)
            Distance: \(run.distanceMeters.distanceString(unit: unit))
            Duration: \(run.durationSeconds.durationString)
            Average pace: \(run.averagePaceSecondsPerKm.paceString(unit: unit))
            Average heart rate: \(run.averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "n/a")
            Max heart rate: \(run.maxHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "n/a")
            How it felt: \(run.feel?.promptDescription ?? "not rated")
            Notes: \(run.notes ?? "none")
            """
        } ?? "Current workout context: none selected."

        let planContext = activePlan.map { plan in
            """
            Active plan:
            Race: \(plan.targetRace.displayName)
            Race date: \(plan.raceDate?.formatted(date: .abbreviated, time: .omitted) ?? "none")
            Goal time: \(plan.goalTimeSeconds.durationString)
            Current week: \(plan.currentWeek?.weekNumber ?? 0) of \(plan.totalWeeks)
            """
        } ?? "Active plan: none."

        let recent = recentRuns
            .prefix(Self.promptRunCount)
            .map { run in
                let hr = run.averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "n/a"
                return "\(run.date.formatted(date: .abbreviated, time: .omitted)) | \(run.workoutType.displayName) | \(run.distanceMeters.distanceString(unit: unit)) | \(run.averagePaceSecondsPerKm.paceString(unit: unit)) | avg HR \(hr)\(RunFeelSignal.historySuffix(for: run.feel))"
            }
            .joined(separator: "\n")

        let recovery = readiness?.promptSummary ?? "Readiness this morning: no Health data."

        return """
        Unit preference: \(unit.rawValue)

        \(selectedRun)

        \(planContext)

        \(recovery)

        Recent runs:
        \(recent.isEmpty ? "No recent runs." : recent)
        """
    }

    private var openingStatus: AICoachCoachStatus {
        // No run history yet: the reply is general guidance, not data-backed.
        guard latestRun != nil else { return .general }
        if (latestRun?.averageHeartRate ?? 0) >= 155 || (latestRun?.maxHeartRate ?? 0) >= 175 {
            return .watchEffort
        }
        return .actionReady
    }

    private var openingMetrics: [AICoachMiniMetric] {
        guard let latestRun else {
            return [
                AICoachMiniMetric(label: "Plan", value: activePlan?.targetRace.localizedName ?? "None", delta: nil, tone: .brand),
                AICoachMiniMetric(label: "Runs", value: "\(recentRuns.count)", delta: nil, tone: .secondary)
            ]
        }

        var metrics: [AICoachMiniMetric] = [
            AICoachMiniMetric(
                label: "Distance",
                value: latestRun.distanceMeters.distanceString(unit: appSettings.unitPreference),
                delta: nil,
                tone: .brand
            ),
            AICoachMiniMetric(
                label: "Pace",
                value: latestRun.averagePaceSecondsPerKm.shortPace(unit: appSettings.unitPreference),
                delta: nil,
                tone: .zoneEasy
            )
        ]

        if let averageHeartRate = latestRun.averageHeartRate {
            metrics.append(
                AICoachMiniMetric(
                    label: "HR avg",
                    value: "\(Int(averageHeartRate.rounded()))",
                    delta: averageHeartRate >= 155 ? "hot" : nil,
                    tone: averageHeartRate >= 155 ? .warning : .success
                )
            )
        }

        return metrics
    }
}

private struct AICoachChatMessage: Identifiable {
    enum Sender {
        case coach
        case runner
    }

    let id = UUID()
    let sender: Sender
    let text: String
    let metrics: [AICoachMiniMetric]
    let status: AICoachCoachStatus?
}

private struct AICoachMiniMetric: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let delta: String?
    let tone: Color
}

private enum AICoachCoachStatus {
    case watchEffort
    case actionReady
    case general
    case setupNeeded

    var title: String {
        switch self {
        case .watchEffort: "WATCH EFFORT"
        case .actionReady: "ACTION READY"
        case .general: "COACH"
        case .setupNeeded: "SETUP"
        }
    }

    var color: Color {
        switch self {
        case .watchEffort: .warning
        case .actionReady: .success
        case .general: .secondary
        case .setupNeeded: .secondary
        }
    }
}

private extension Double {
    func shortPace(unit: UnitPreference) -> String {
        paceString(unit: unit)
            .replacingOccurrences(of: " min/km", with: "")
            .replacingOccurrences(of: " min/mi", with: "")
    }
}
