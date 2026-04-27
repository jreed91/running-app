import SwiftUI
import MapKit
import Charts
import SwiftData

struct RunSummaryView: View {
    let workout: RunWorkout

    @Environment(AppSettings.self) private var appSettings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainer) private var container
    @Query private var scheduledWorkouts: [ScheduledWorkout]
    @Query(sort: \RunWorkout.date, order: .reverse) private var allWorkouts: [RunWorkout]
    @Query private var profiles: [UserProfile]

    // Chart selection state
    @State private var selectedSplitPaceKm: Int? = nil
    @State private var selectedSplitHRKm: Int? = nil
    @State private var selectedSplitElevKm: Int? = nil
    @State private var showDeleteConfirmation = false
    @State private var showAssociateSheet = false
    @State private var aiInsight: AICoachInsight?
    @State private var isLoadingAIInsight = false
    @State private var aiStreamBuffer = ""
    @State private var showFullAIAnalysis = false
    @State private var aiReaction: AIReaction?

    private var matchedScheduled: ScheduledWorkout? {
        scheduledWorkouts.first { $0.completedWorkout?.id == workout.id }
    }

    private var estimatedVO2Max: Double? {
        guard workout.distanceMeters >= 400, workout.durationSeconds > 0 else { return nil }
        let v = PaceCalculatorService.vdot(distanceMeters: workout.distanceMeters, timeSeconds: workout.durationSeconds)
        return v > 0 ? v : nil
    }

    private var hasSplitHR: Bool {
        workout.splits.contains { $0.heartRate != nil }
    }

    private var hasSplitElevation: Bool {
        workout.splits.contains { $0.elevationGainMeters != 0 }
    }

    private func split(forKm km: Int) -> Split? {
        workout.splits.first { $0.kilometer == km }
    }

    private var recentHistory: [RunWorkout] {
        allWorkouts.filter { $0.id != workout.id }
    }

    private var displayType: WorkoutType {
        workout.scheduledWorkout?.workoutType ?? workout.workoutType
    }

    private var workoutTone: Color {
        displayType.color
    }

    private var titleMetric: (value: String, unit: String) {
        let converted = appSettings.unitPreference == .imperial
            ? workout.distanceMeters / 1_609.344
            : workout.distanceMeters / 1_000
        return (String(format: "%.2f", converted), appSettings.unitPreference.distanceLabel)
    }

    private var routeName: String {
        if let name = workout.scheduledWorkout?.week?.plan?.raceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return workout.scheduledWorkout?.workoutType.displayName ?? "\(workout.workoutLocation.displayName) Run"
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                titleBlock
                if workout.scheduledWorkout == nil {
                    linkToPlannedWorkoutButton
                }
                routeMap
                statsGrid
                weatherSection
                performanceFeedbackSection
                aiCoachSection
                if !workout.splits.isEmpty {
                    splitPaceChart
                    if hasSplitHR { splitHRChart }
                    if hasSplitElevation { splitElevationChart }
                    splitsTable
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color.surfacePrimary.ignoresSafeArea())
        .navigationTitle(displayType.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(isPresented: $showAssociateSheet) {
            AssociateWorkoutSheet(workout: workout)
        }
        .confirmationDialog("Delete this workout?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                workout.scheduledWorkout?.completedWorkout = nil
                context.delete(workout)
                try? context.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This workout will be permanently removed.")
        }
        .task {
            guard workout.weather == nil, let coord = workout.routeCoordinates.first else { return }
            await container.attachWeather(to: workout, coordinate: coord)
        }
    }

    // MARK: Link to planned workout

    private var linkToPlannedWorkoutButton: some View {
        Button {
            showAssociateSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.brand)
                Text("Link to a planned workout")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.brand)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: Title block

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(workoutTone)
                    .frame(width: 8, height: 8)
                    .shadow(color: workoutTone.opacity(0.35), radius: 0, x: 0, y: 0)
                    .overlay(Circle().stroke(workoutTone.opacity(0.25), lineWidth: 6))
                Text("\(displayType.displayName) run")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(workoutTone)
                Circle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3, height: 3)
                Text(workout.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(titleMetric.value)
                    .font(.system(size: 56, weight: .semibold, design: .monospaced))
                    .kerning(-2.2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(titleMetric.unit)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                metricInline(value: workout.durationSeconds.durationString, label: "total")
                Text("·").foregroundStyle(.tertiary)
                metricInline(
                    value: workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference).replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: ""),
                    label: appSettings.unitPreference.paceLabel
                )
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricInline(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Route map

    private var routeMap: some View {
        Group {
            if workout.routeCoordinates.isEmpty {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.surfaceSecondary)
                    .frame(height: 180)
                    .overlay {
                        Label("No route data", systemImage: "map")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
            } else {
                ZStack(alignment: .topLeading) {
                    Map {
                        MapPolyline(coordinates: workout.routeCoordinates.map(\.clCoordinate))
                            .stroke(.brand, lineWidth: 4)
                    }
                    Text(routeName)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: Stats grid

    private var statsGrid: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
            statCell(value: titleMetric.value, unit: titleMetric.unit, label: "Distance")
            statCell(value: workout.durationSeconds.durationString, label: "Duration")
            statCell(
                value: workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference).replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: ""),
                unit: appSettings.unitPreference.paceLabel,
                label: "Avg Pace"
            )
            if let hr = workout.averageHeartRate {
                statCell(value: "\(Int(hr))", unit: "bpm", label: "Avg HR", tone: hrTone(hr))
            }
            if let maxHR = workout.maxHeartRate {
                statCell(value: "\(Int(maxHR))", unit: "bpm", label: "Max HR", tone: hrTone(maxHR))
            }
            if let gain = workout.elevationGainMeters {
                statCell(
                    value: "\(Int(gain.elevationValue(unit: appSettings.unitPreference)))",
                    unit: appSettings.unitPreference.elevationLabel,
                    label: "Elevation"
                )
            }
            if let vo2 = estimatedVO2Max {
                statCell(value: String(format: "%.1f", vo2), label: "Est. VO₂ Max", colSpan: true)
            }
        }
    }

    private func statCell(value: String, unit: String? = nil, label: String, tone: Color? = nil, colSpan: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .kerning(-0.5)
                    .foregroundStyle(tone ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        .gridCellColumns(colSpan ? 2 : 1)
    }

    private func hrTone(_ value: Double) -> Color? {
        value >= 155 ? .warning : nil
    }

    // MARK: Weather section

    @ViewBuilder
    private var weatherSection: some View {
        if let w = workout.weather {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: "Conditions")

                HStack(spacing: 0) {
                    // Icon + condition description
                    VStack(spacing: 6) {
                        Image(systemName: w.conditionSymbol)
                            .font(.system(size: 32))
                            .symbolRenderingMode(.multicolor)
                        Text(w.conditionDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 56)

                    // Temperature
                    VStack(spacing: 4) {
                        Text(w.temperatureString(unit: appSettings.unitPreference))
                            .font(.metricSmall)
                        Text("Feels \(w.feelsLikeString(unit: appSettings.unitPreference))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 56)

                    // Humidity + wind
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(Int(w.humidityPercent))%", systemImage: "humidity")
                        Label(w.windString(unit: appSettings.unitPreference), systemImage: "wind")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }



    // MARK: AI coach section

    @ViewBuilder
    private var aiCoachSection: some View {
        if appSettings.aiInsightsEnabled {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            SparkleShape()
                                .fill(Color.brand)
                                .frame(width: 11, height: 11)
                            Text("AI COACH")
                                .font(.system(size: 11, weight: .bold))
                                .kerning(1.4)
                                .foregroundStyle(.brand)
                        }
                        Text("Today's analysis")
                            .font(.system(size: 18, weight: .bold))
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
                                .fill(.white)
                                .frame(width: 11, height: 11)
                            Text(aiInsight == nil ? "Load" : "Refresh")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.brand, in: Capsule())
                        .shadow(color: Color.brand.opacity(0.35), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingAIInsight || !hasAIKey)
                }
                .padding(.horizontal, 4)

                if isLoadingAIInsight {
                    aiCoachSkeletonSection
                } else if let aiInsight {
                    if aiInsight.apiReady {
                        aiDiagnosisCard(aiInsight)
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

    private func aiDiagnosisCard(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SparkleShape()
                    .fill(Color.brand)
                    .frame(width: 14, height: 14)
                Text("DIAGNOSIS")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(.brand)
                Spacer()
                confidenceChip(insight.confidence)
            }

            Text(normalizedMarkdownText(insight.headline))
                .font(.system(size: 22, weight: .heavy))
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
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.warning.opacity(0.28), lineWidth: 0.5))
    }

    private func aiActionPlan(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DO THIS NEXT")
                .font(.system(size: 11, weight: .bold))
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
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.success.opacity(0.14))
                    .frame(width: 40, height: 40)
                StrideIcon(name: .run, size: 20, color: .success, strokeWeight: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT SESSION")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(normalizedMarkdownText(insight.nextWorkoutSuggestion))
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(2)
                if let rationale = insight.nextWorkoutRationale?.trimmingCharacters(in: .whitespacesAndNewlines), !rationale.isEmpty {
                    Text(normalizedMarkdownText(rationale))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            StrideIcon(name: .chevronRight, size: 14, color: .secondary, strokeWeight: 2.4)
        }
        .padding(14)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.brand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
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
                .font(.system(size: 10, weight: .bold))
                .kerning(1.1)
                .foregroundStyle(.secondary)

            Text(normalizedMarkdownText(fullAnalysisText(for: insight)))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func fullAnalysisText(for insight: AICoachInsight) -> String {
        if let fullAnalysis = insight.fullAnalysis?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fullAnalysis.isEmpty {
            return fullAnalysis
        }

        let actionSummary = insight.actionItems
            .prefix(3)
            .map { "\($0.title): \($0.detail)" }
            .joined(separator: " ")
        let nextWorkoutParts: [String?] = [
            "Next session: \(insight.nextWorkoutSuggestion).",
            insight.nextWorkoutRationale
        ]
        let nextWorkout = nextWorkoutParts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return [insight.summary, actionSummary, nextWorkout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func reactionButton(_ reaction: AIReaction) -> some View {
        Button {
            withAnimation(AppAnimation.snappy) {
                aiReaction = aiReaction == reaction ? nil : reaction
            }
        } label: {
            Image(systemName: reaction == .up ? "hand.thumbsup" : "hand.thumbsdown")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(aiReaction == reaction ? Color.brand : Color.secondary)
                .frame(width: 48, height: 48)
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func aiAttribution(_ insight: AICoachInsight) -> some View {
        HStack(spacing: 5) {
            SparkleShape()
                .fill(Color.success)
                .frame(width: 11, height: 11)
            Text("Generated by \(appSettings.aiProvider.displayName) · \(workout.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private var aiEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hasAIKey ? "Ready for analysis" : "API key required")
                .font(.system(size: 15, weight: .bold))
            Text(hasAIKey
                 ? "Tap Load to fetch AI coaching feedback for this workout."
                 : "Add your AI API key in Settings to load cloud AI workout analysis.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func aiUnavailableCard(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(normalizedMarkdownText(insight.headline))
                .font(.system(size: 15, weight: .bold))
            Text(normalizedMarkdownText(insight.summary))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Skeleton loading

    private var aiCoachSkeletonSection: some View {
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
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))

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
                    .background(.surfaceTertiary, in: RoundedRectangle(cornerRadius: 10))
                }
            }

            // Next Session skeleton
            VStack(alignment: .leading, spacing: 6) {
                AIInsightSkeletonShape().frame(width: 90, height: 11)
                AIInsightSkeletonShape().frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                AIInsightSkeletonShape().frame(maxWidth: 200, minHeight: 11, maxHeight: 11)
            }
            .padding()
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private struct AIInsightSkeletonShape: View {
        @State private var opacity: Double = 0.12

        var body: some View {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(opacity))
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        opacity = 0.28
                    }
                }
        }
    }

    private func normalizedMarkdownText(_ text: String) -> String {
        var output = text
        let replacements = ["**", "__", "`", "###", "##", "#", ">", "_"]
        replacements.forEach { output = output.replacingOccurrences(of: $0, with: "") }

        let prefixes = ["- ", "* ", "+ "]
        for prefix in prefixes where output.hasPrefix(prefix) {
            output.removeFirst(prefix.count)
        }

        if let range = output.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            output.removeSubrange(range)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct AIActionItemRow: View {
        let action: AICoachActionItem

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(priorityColor)
                    .font(.caption)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(cleaned(action.title))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(cleaned(action.priority).uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(priorityColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(priorityColor.opacity(0.12), in: Capsule())
                    }

                    Text(cleaned(action.detail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(.surfaceTertiary, in: RoundedRectangle(cornerRadius: 10))
        }

        private var priorityColor: Color {
            switch action.priority.lowercased() {
            case "high":
                return .warning
            case "low":
                return .secondary
            default:
                return .success
            }
        }

        private func cleaned(_ text: String) -> String {
            var output = text
            ["**", "__", "`", "###", "##", "#", ">", "_"].forEach {
                output = output.replacingOccurrences(of: $0, with: "")
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @MainActor
    private func loadAIInsight() async {
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

        let historySlice = Array(recentHistory.prefix(8))
        aiInsight = await container.aiCoachService.evaluateWithProvider(
            workout: workout,
            recentHistory: historySlice,
            profile: profiles.first,
            provider: appSettings.aiProvider,
            apiKey: appSettings.aiAPIKey,
            modelOverride: appSettings.aiModelOverride,
            unitPreference: appSettings.unitPreference,
            onChunk: { chunk in
                Task { @MainActor in
                    appendInsightStreamChunk(chunk)
                }
            }
        )
    }

    @MainActor
    private func appendInsightStreamChunk(_ chunk: String) {
        aiStreamBuffer += chunk
    }

    private var hasAIKey: Bool {
        !appSettings.aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Split pace chart

    private var splitPaceChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "Splits")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Pace per \(appSettings.unitPreference.distanceLabel)")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    splitTab("Pace", active: true)
                    splitTab("HR", active: false)
                    splitTab("Elev", active: false)
                }
            Chart {
                ForEach(workout.splits, id: \.kilometer) { split in
                    BarMark(
                        x: .value(appSettings.unitPreference.distanceLabel, split.kilometer),
                        y: .value("Pace", split.paceSecondsPerKm)
                    )
                    .foregroundStyle(selectedSplitPaceKm == split.kilometer ? Color.brand : Color.brand.opacity(selectedSplitPaceKm == nil ? 1.0 : 0.5))
                }
                if let km = selectedSplitPaceKm, let split = split(forKm: km) {
                    RuleMark(x: .value(appSettings.unitPreference.distanceLabel, km))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(appSettings.unitPreference.distanceLabel) \(km)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(split.paceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                                    .font(.caption).bold()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                }
            }
            .frame(height: 120)
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let secs = value.as(Double.self) {
                            Text(secs.paceString(unit: appSettings.unitPreference)
                                .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: ""))
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedSplitPaceKm)
            Text("Lower = faster").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Split HR chart

    private var splitHRChart: some View {
        let hrSplits = workout.splits.filter { $0.heartRate != nil }
        return VStack(alignment: .leading, spacing: 8) {
            Text("HEART RATE BY SPLIT").font(.sectionHeader).foregroundStyle(.secondary).padding(.horizontal, 4)
            Chart {
                ForEach(hrSplits, id: \.kilometer) { split in
                    LineMark(
                        x: .value(appSettings.unitPreference.distanceLabel, split.kilometer),
                        y: .value("bpm", split.heartRate ?? 0)
                    )
                    .foregroundStyle(.zoneInterval)
                    PointMark(
                        x: .value(appSettings.unitPreference.distanceLabel, split.kilometer),
                        y: .value("bpm", split.heartRate ?? 0)
                    )
                    .foregroundStyle(.zoneInterval)
                    .symbolSize(selectedSplitHRKm == split.kilometer ? 80 : 36)
                }
                if let km = selectedSplitHRKm, let split = split(forKm: km), let hr = split.heartRate {
                    RuleMark(x: .value(appSettings.unitPreference.distanceLabel, km))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(appSettings.unitPreference.distanceLabel) \(km)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text("\(Int(hr)) bpm")
                                    .font(.caption).bold()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                }
            }
            .frame(height: 120)
            .chartYAxisLabel("bpm")
            .chartXSelection(value: $selectedSplitHRKm)
        }
    }

    // MARK: Split elevation chart

    private var splitElevationChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ELEVATION BY SPLIT").font(.sectionHeader).foregroundStyle(.secondary).padding(.horizontal, 4)
            Chart {
                ForEach(workout.splits, id: \.kilometer) { split in
                    let gain = split.elevationGainMeters.elevationValue(unit: appSettings.unitPreference)
                    BarMark(
                        x: .value(appSettings.unitPreference.distanceLabel, split.kilometer),
                        y: .value(appSettings.unitPreference.elevationLabel, gain)
                    )
                    .foregroundStyle(
                        (gain >= 0 ? Color.success : Color.destructive)
                            .opacity(selectedSplitElevKm == nil || selectedSplitElevKm == split.kilometer ? 1.0 : 0.5)
                    )
                }
                if let km = selectedSplitElevKm, let split = split(forKm: km) {
                    let gain = split.elevationGainMeters.elevationValue(unit: appSettings.unitPreference)
                    RuleMark(x: .value(appSettings.unitPreference.distanceLabel, km))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(appSettings.unitPreference.distanceLabel) \(km)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text("\(gain >= 0 ? "+" : "")\(Int(gain)) \(appSettings.unitPreference.elevationLabel)")
                                    .font(.caption).bold()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                }
            }
            .frame(height: 100)
            .chartYAxisLabel(appSettings.unitPreference.elevationLabel)
            .chartXSelection(value: $selectedSplitElevKm)
        }
    }

    // MARK: Splits table

    private var splitsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(appSettings.unitPreference.distanceLabel.uppercased())
                    .frame(width: 36, alignment: .leading)
                Spacer()
                Text("PACE")
                if hasSplitHR {
                    Text("HR").frame(width: 60, alignment: .trailing)
                }
                Text("ELEV").frame(width: 60, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(workout.splits, id: \.kilometer) { split in
                splitRow(split)
                Divider()
            }
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func splitRow(_ split: Split) -> some View {
        HStack {
            Text("\(split.kilometer)")
                .frame(width: 36, alignment: .leading)
                .font(.bodyRegular)
            Spacer()
            Text(split.paceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                .font(.bodyStrong)
            if hasSplitHR {
                Group {
                    if let hr = split.heartRate {
                        Text("\(Int(hr))").foregroundStyle(.zoneInterval)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 60, alignment: .trailing)
                .font(.caption)
            }
            elevationCell(split.elevationGainMeters)
                .frame(width: 60, alignment: .trailing)
                .font(.caption)
        }
    }

    @ViewBuilder
    private func elevationCell(_ meters: Double) -> some View {
        if meters != 0 {
            let g = meters.elevationValue(unit: appSettings.unitPreference)
            Text("\(g >= 0 ? "+" : "")\(Int(g))\(appSettings.unitPreference.elevationLabel)")
                .foregroundStyle(g >= 0 ? Color.success : Color.destructive)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    // MARK: Performance Feedback

    @ViewBuilder
    private var performanceFeedbackSection: some View {
        if let feedback = performanceFeedback {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(feedback.color)
                        .frame(width: 24, height: 24)
                    Image(systemName: feedback.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(feedback.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(feedback.color)
                    Text(feedback.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(feedback.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(feedback.color.opacity(0.22), lineWidth: 0.5))
        }
    }

    private var performanceFeedback: RunPerformanceFeedback? {
        if let scheduled = matchedScheduled, let targetRange = scheduled.targetPaceRange {
            let actual = workout.averagePaceSecondsPerKm
            let status = paceStatus(actual: actual, target: targetRange)
            let targetText = "\(targetRange.lowerBound.paceString(unit: appSettings.unitPreference)) - \(targetRange.upperBound.paceString(unit: appSettings.unitPreference))"
            return RunPerformanceFeedback(
                title: status.label,
                detail: "Target \(targetText); you averaged \(actual.paceString(unit: appSettings.unitPreference)).",
                icon: status.icon,
                color: status.color
            )
        }

        if let avg = workout.averageHeartRate, avg >= 155 {
            return RunPerformanceFeedback(
                title: "Effort higher than expected",
                detail: "HR averaged \(Int(avg)) bpm for this \(workout.workoutType.displayName.lowercased()) effort.",
                icon: "exclamationmark",
                color: .warning
            )
        }

        return nil
    }

    private func sectionHeader(title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
    }

    private func splitTab(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(active ? Color.brand : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(active ? Color.brand.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func confidenceChip(_ value: Int) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 36, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.brand)
                        .frame(width: 36 * CGFloat(value) / 100, height: 4)
                }
            Text("\(value)%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func evidenceChip(label: String, sub: String?, tone: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
            if let sub {
                Text(sub)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tone)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func aiTone(_ raw: String) -> Color {
        switch raw.lowercased() {
        case "easy":
            return .zoneEasy
        case "brand", "medium":
            return .brand
        case "interval", "high":
            return .zoneInterval
        case "warning":
            return .warning
        case "success", "low":
            return .success
        default:
            return .secondary
        }
    }

    private enum AIReaction {
        case up
        case down
    }

    private struct RunPerformanceFeedback {
        let title: String
        let detail: String
        let icon: String
        let color: Color
    }

    private struct SparkleShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.midY - rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.midY + rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.midY + rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.midY - rect.height * 0.12))
            path.closeSubpath()
            return path
        }
    }

    private struct AIActionCard: View {
        let number: String
        let title: String
        let detail: String
        let metric: String?
        let tone: Color

        var bodyView: some View {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tone)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(number)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .kerning(0.6)
                            .foregroundStyle(tone)
                        Text(title)
                            .font(.system(size: 15, weight: .bold))
                            .kerning(-0.2)
                    }
                    Text(detail)
                        .font(.system(size: 13))
                        .lineSpacing(1)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                if let metric {
                    Text(metric)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(tone)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(14)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
        }

        var body: some View {
            bodyView
        }
    }

    private struct PaceStatus {
        let label: String
        let icon: String
        let color: Color
    }

    private func paceStatus(actual: Double, target: ClosedRange<Double>) -> PaceStatus {
        if target.contains(actual) {
            return PaceStatus(label: "On target", icon: "checkmark.circle.fill", color: .success)
        }
        let margin = (target.upperBound - target.lowerBound) * 0.1 + target.upperBound * 0.05
        if actual <= target.upperBound + margin && actual >= target.lowerBound - margin {
            return PaceStatus(label: "Slightly off target", icon: "exclamationmark.circle.fill", color: .warning)
        }
        if actual < target.lowerBound {
            return PaceStatus(label: "Too fast", icon: "bolt.fill", color: .warning)
        }
        return PaceStatus(label: "Too slow", icon: "tortoise.fill", color: .destructive)
    }
}
