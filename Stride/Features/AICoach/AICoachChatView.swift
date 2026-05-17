import SwiftUI
import SwiftData

struct AICoachChatView: View {
    @Environment(AppSettings.self) private var appSettings

    @Query(sort: [SortDescriptor(\RunWorkout.date, order: .reverse)])
    private var recentRuns: [RunWorkout]

    @Query(
        filter: #Predicate<TrainingPlan> { $0.isActive },
        sort: \TrainingPlan.createdAt, order: .reverse
    )
    private var activePlans: [TrainingPlan]

    @State private var messages: [AICoachChatMessage] = []
    @State private var draft = ""
    @FocusState private var isComposerFocused: Bool

    private var latestRun: RunWorkout? { recentRuns.first }
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
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 18)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) { _, _ in
                        scrollToLatest(proxy)
                    }
                    .onAppear {
                        seedConversationIfNeeded()
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
                }
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
                        send(prompt)
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
                    send(draft)
                }

            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(canSendDraft ? Color.brand : Color.secondary.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSendDraft)
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

                Text(message.text)
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

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        withAnimation(AppAnimation.snappy) {
            messages.append(
                AICoachChatMessage(
                    sender: .runner,
                    text: trimmed,
                    metrics: [],
                    status: nil
                )
            )
            messages.append(reply(for: trimmed))
        }
        draft = ""
    }

    private func seedConversationIfNeeded() {
        guard messages.isEmpty else { return }
        messages = [
            AICoachChatMessage(
                sender: .coach,
                text: openingCoachMessage,
                metrics: openingMetrics,
                status: openingStatus
            )
        ]
    }

    private func reply(for prompt: String) -> AICoachChatMessage {
        let lower = prompt.lowercased()
        let response: String
        let status: AICoachCoachStatus?

        if lower.contains("why") || lower.contains("high") {
            response = effortExplanation
            status = .watchEffort
        } else if lower.contains("rest") || lower.contains("tomorrow") || lower.contains("adjust") {
            response = nextStepExplanation
            status = .actionReady
        } else if lower.contains("last 5") || lower.contains("easy run") {
            response = recentRunsExplanation
            status = .dataBacked
        } else {
            response = generalExplanation(for: prompt)
            status = openingStatus
        }

        return AICoachChatMessage(
            sender: .coach,
            text: response,
            metrics: openingMetrics,
            status: status
        )
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        withAnimation(AppAnimation.snappy) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var canSendDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasAIKey: Bool {
        !appSettings.aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private var openingStatus: AICoachCoachStatus {
        guard latestRun != nil else { return .dataBacked }
        if (latestRun?.averageHeartRate ?? 0) >= 155 || (latestRun?.maxHeartRate ?? 0) >= 175 {
            return .watchEffort
        }
        return .actionReady
    }

    private var openingCoachMessage: String {
        guard let latestRun else {
            if let activePlan {
                return "I have your \(activePlan.targetRace.displayName) plan context. Ask me how to approach the next workout, where recovery fits, or how your paces should feel."
            }
            return "Once you log or import a run, I can answer follow-ups using your recent workouts, plan, and pace zones. For now, ask about training structure or recovery."
        }

        let workoutLabel = latestRun.workoutType.displayName.lowercased()
        let distance = latestRun.distanceMeters.distanceString(unit: appSettings.unitPreference)
        let pace = latestRun.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference)
        let effortNote = effortRead(for: latestRun)

        return "That \(workoutLabel) run was \(distance) at \(pace). \(effortNote) Ask me why it felt that way, how to adjust tomorrow, or what pattern shows up across your recent runs."
    }

    private var effortExplanation: String {
        guard let run = latestRun else {
            return "The strongest signal usually comes from pace relative to heart rate. Once a run is logged, I compare effort, distance, and recent workload before calling something easy, hot, or under-recovered."
        }

        let heartRate = run.averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "your available heart-rate data"
        let maxHeartRate = run.maxHeartRate.map { " with a max of \(Int($0.rounded()))" } ?? ""
        return "The effort flag comes from the gap between the intended run and the physiological cost. This run averaged \(heartRate)\(maxHeartRate), so I would keep the next aerobic session capped by effort instead of chasing pace."
    }

    private var nextStepExplanation: String {
        guard latestRun != nil else {
            return "For tomorrow, keep the first decision simple: if your legs feel flat or your resting HR is elevated, make it rest or low-impact cross-training. Otherwise, keep the next run conversational."
        }

        return "Tomorrow should stay boring in the best way: rest, walk, or cross-train if soreness is lingering. If you do run, cap it at easy effort and stop the moment the heart-rate drift shows up again."
    }

    private var recentRunsExplanation: String {
        let runs = Array(recentRuns.prefix(5))
        guard !runs.isEmpty else {
            return "I need a few completed runs before I can compare trends. After that, I can look for pace creep, heart-rate drift, long-run recovery, and whether easy days are actually easy."
        }

        let totalDistance = runs.reduce(0) { $0 + $1.distanceMeters }
        let avgPace = runs.map(\.averagePaceSecondsPerKm).filter { $0 > 0 }.average
        let paceText = avgPace.map { $0.paceString(unit: appSettings.unitPreference) } ?? "unknown pace"
        return "Across your last \(runs.count) runs, you covered \(totalDistance.distanceString(unit: appSettings.unitPreference)) with an average pace around \(paceText). The first thing I would check is whether easy days are drifting faster as fatigue rises."
    }

    private func generalExplanation(for prompt: String) -> String {
        "For \"\(prompt),\" I would start with three checks: recent workload, the intent of the next scheduled workout, and whether your last easy effort looked truly easy. From there, the safest adjustment is usually effort first, distance second, pace last."
    }

    private func effortRead(for run: RunWorkout) -> String {
        if let averageHeartRate = run.averageHeartRate, averageHeartRate >= 155 {
            return "Your average heart rate was high enough that I would treat it as a recovery warning, not just a pace note."
        }
        if let maxHeartRate = run.maxHeartRate, maxHeartRate >= 175 {
            return "The max heart-rate spike is the signal I would watch before stacking another hard session."
        }
        return "The effort looks controlled, so the next useful question is whether this fits the week's workload."
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
    case dataBacked

    var title: String {
        switch self {
        case .watchEffort: "WATCH EFFORT"
        case .actionReady: "ACTION READY"
        case .dataBacked: "DATA BACKED"
        }
    }

    var color: Color {
        switch self {
        case .watchEffort: .warning
        case .actionReady: .success
        case .dataBacked: .brand
        }
    }
}

private extension Array where Element == Double {
    var average: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}

private extension Double {
    func shortPace(unit: UnitPreference) -> String {
        paceString(unit: unit)
            .replacingOccurrences(of: " min/km", with: "")
            .replacingOccurrences(of: " min/mi", with: "")
    }
}
