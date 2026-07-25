import SwiftUI
import SwiftData

struct AICoachChatView: View {
    private let workoutContext: RunWorkout?
    private let initialPrompt: String?

    @Environment(AppSettings.self) private var appSettings
    @Environment(\.appContainer) private var container

    /// How many recent runs the coach prompt summarises. Also the fetch limit below —
    /// the prompt is the only consumer of more than the newest run.
    private static let promptRunCount = 8

    /// Newest runs only. This used to fetch the entire runs table on every open of the
    /// chat, for a prompt that reads eight of them (D6).
    ///
    /// Nothing here needs a true total: the header's "Runs" count is only rendered when
    /// there is no latest run at all, which means this fetch came back empty.
    static var recentRunsDescriptor: FetchDescriptor<RunWorkout> {
        var descriptor = FetchDescriptor<RunWorkout>(
            sortBy: [SortDescriptor(\RunWorkout.date, order: .reverse)]
        )
        descriptor.fetchLimit = promptRunCount
        return descriptor
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
    @State private var didSendInitialPrompt = false
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
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            contextHeader
                            ForEach(messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                            if isWaitingForCoach {
                                typingRow
                                    .id("typing")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 18)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) { _, _ in
                        scrollToLatest(proxy)
                    }
                    .onChange(of: isWaitingForCoach) { _, _ in
                        scrollToLatest(proxy)
                    }
                }

                quickReplies
                composer
            }
            .background(Color.surfacePrimary)
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.brand)
                        .frame(width: 36, height: 36)
                        .background(.surfaceSecondary, in: Circle())
                        // Decoration, not a control — it reads as "sparkles" otherwise.
                        .accessibilityHidden(true)
                }
            }
            .task {
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
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(.brand)
                    Text(contextSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                readinessBadge
            }

            Text("Ask follow-ups about your last run, training plan, recovery, or pacing. Stride keeps the answers grounded in your recent data.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))
    }

    private var readinessBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(appSettings.aiInsightsEnabled && hasAIKey ? Color.success : Color.warning)
                .frame(width: 6, height: 6)
            Text(appSettings.aiInsightsEnabled && hasAIKey ? "READY" : "SETUP")
                .font(.system(size: 10, weight: .bold))
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.brand)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.surfaceSecondary, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.brand.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.surfacePrimary)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.brand)

            TextField("Ask your coach...", text: $draft, axis: .vertical)
                .font(.system(size: 15))
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
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(canSendDraft ? Color.brand : Color.secondary.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSendDraft || isWaitingForCoach)
            .accessibilityLabel("Send message")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(.surfaceSecondary, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
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

                Text(markdownText(message.text))
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(message.sender == .coach ? Color.primary : Color.white)
                    .fixedSize(horizontal: false, vertical: true)

                if !message.metrics.isEmpty {
                    metricGrid(message.metrics)
                }
            }
            .padding(14)
            .background(message.sender == .coach ? Color.surfaceSecondary : Color.brand, in: bubbleShape(for: message))
            .overlay {
                if message.sender == .coach {
                    bubbleShape(for: message)
                        .strokeBorder(Color.secondary.opacity(0.08), lineWidth: 0.5)
                }
            }
            .frame(maxWidth: 310, alignment: message.sender == .coach ? .leading : .trailing)

            if message.sender == .coach {
                Spacer(minLength: 20)
            }
        }
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
                        .animation(
                            .easeInOut(duration: 0.7)
                                .repeatForever()
                                .delay(Double(index) * 0.12),
                            value: isWaitingForCoach
                        )
                }
            }
            .padding(14)
            .background(.surfaceSecondary, in: UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: 18))
            Spacer(minLength: 20)
        }
    }

    private func coachBubbleHeader(_ message: AICoachChatMessage) -> some View {
        HStack(spacing: 6) {
            Text("Coach")
                .font(.system(size: 13, weight: .bold))
            if let status = message.status {
                HStack(spacing: 5) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 5, height: 5)
                    Text(status.title)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                }
                .foregroundStyle(status.color)
                .padding(.horizontal, 8)
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
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(metric.value)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                        if let delta = metric.delta {
                            Text(delta)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(metric.tone)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.surfaceTertiary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func coachAvatar(size: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [.brand, .zoneInterval],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(color: Color.brand.opacity(0.35), radius: 10, y: 5)
    }

    private func bubbleShape(for message: AICoachChatMessage) -> some InsettableShape {
        UnevenRoundedRectangle(
            topLeadingRadius: message.sender == .coach ? 4 : 18,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: message.sender == .coach ? 18 : 4,
            topTrailingRadius: 18
        )
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
            let setupText = "Turn on AI Coach in Settings to chat with \(appSettings.aiProvider.displayName)."
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
        defer { isWaitingForCoach = false }

        // The metric chips and status badge summarize the run the conversation
        // opened on. They belong to the first coach reply only — repeating them on
        // every answer implies each reply is freshly grounded in that same data.
        let isOpeningReply = !messages.contains { $0.sender == .coach }

        do {
            let reply = try await container.aiCoachService.chatWithProvider(
                provider: appSettings.aiProvider,
                context: coachContext,
                messages: providerMessages
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
                        text: "I could not reach \(appSettings.aiProvider.displayName). Make sure Apple Intelligence is enabled on this device, then try again.",
                        metrics: [],
                        status: .setupNeeded
                    )
                )
            }
        }
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

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if isWaitingForCoach {
            withAnimation(AppAnimation.snappy) {
                proxy.scrollTo("typing", anchor: .bottom)
            }
            return
        }
        guard let last = messages.last else { return }
        withAnimation(AppAnimation.snappy) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var canSendDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func markdownText(_ text: String) -> AttributedString {
        // A sixth copy of the same fallback, and the weakest of them — it stripped only
        // `**`, so a backtick or heading marker showed up raw in chat (N27).
        CoachMarkdown.attributed(text)
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
            "After \(latestRun.workoutType.displayName.lowercased()) run"
        } else if let activePlan {
            "\(activePlan.targetRace.displayName) plan context"
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
                return "\(run.date.formatted(date: .abbreviated, time: .omitted)) | \(run.workoutType.displayName) | \(run.distanceMeters.distanceString(unit: unit)) | \(run.averagePaceSecondsPerKm.paceString(unit: unit)) | avg HR \(hr)"
            }
            .joined(separator: "\n")

        return """
        Unit preference: \(unit.rawValue)

        \(selectedRun)

        \(planContext)

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
                AICoachMiniMetric(label: "Plan", value: activePlan?.targetRace.displayName ?? "None", delta: nil, tone: .brand),
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
