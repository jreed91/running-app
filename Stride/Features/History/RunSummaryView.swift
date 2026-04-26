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
    @State private var aiInsight: AICoachInsight?
    @State private var isLoadingAIInsight = false

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


    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
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
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(workout.workoutType.displayName)
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
    }

    // MARK: Route map

    private var routeMap: some View {
        Group {
            if workout.routeCoordinates.isEmpty {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.surfaceSecondary)
                    .frame(height: 220)
                    .overlay { Label("No route data", systemImage: "map") }
            } else {
                Map {
                    MapPolyline(coordinates: workout.routeCoordinates.map(\.clCoordinate))
                        .stroke(.brand, lineWidth: 4)
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: Stats grid

    private var statsGrid: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 16) {
            statCell(value: workout.distanceMeters.distanceString(unit: appSettings.unitPreference), label: "Distance")
            statCell(value: workout.durationSeconds.durationString, label: "Duration")
            statCell(
                value: workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference),
                label: "Avg Pace"
            )
            if let hr = workout.averageHeartRate {
                statCell(value: "\(Int(hr)) bpm", label: "Avg HR")
            }
            if let maxHR = workout.maxHeartRate {
                statCell(value: "\(Int(maxHR)) bpm", label: "Max HR")
            }
            if let gain = workout.elevationGainMeters {
                statCell(
                    value: "+\(Int(gain.elevationValue(unit: appSettings.unitPreference))) \(appSettings.unitPreference.elevationLabel)",
                    label: "Elevation"
                )
            }
            if let vo2 = estimatedVO2Max {
                statCell(value: String(format: "%.1f", vo2), label: "Est. VO₂ Max")
            }
        }
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.metricSmall)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Weather section

    @ViewBuilder
    private var weatherSection: some View {
        if let w = workout.weather {
            VStack(alignment: .leading, spacing: 12) {
                Text("CONDITIONS")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)

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
                .padding()
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }



    // MARK: AI coach section

    @ViewBuilder
    private var aiCoachSection: some View {
        if appSettings.aiInsightsEnabled {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("AI COACH", systemImage: "sparkles")
                        .font(.sectionHeader)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task {
                            await loadAIInsight()
                        }
                    } label: {
                        if isLoadingAIInsight {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                        } else {
                            Label(aiInsight == nil ? "Load Insights" : "Refresh", systemImage: "sparkles")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isLoadingAIInsight || !hasAIKey)
                }

                if let aiInsight {
                    HStack(spacing: 8) {
                        Image(systemName: aiInsight.apiReady ? "checkmark.seal.fill" : "info.circle.fill")
                            .foregroundStyle(aiInsight.apiReady ? .success : .secondary)
                        Text(normalizedMarkdownText(aiInsight.headline))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(aiInsight.apiReady ? .success : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.surfaceTertiary, in: Capsule())

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Workout Summary", systemImage: "waveform.path.ecg")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(markdownParagraphs(from: aiInsight.summary), id: \.self) { paragraph in
                            Text(paragraph)
                                .font(.bodyRegular)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding()
                    .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))

                    if !aiInsight.focusAreas.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Focus Areas", systemImage: "target")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(aiInsight.focusAreas.map(normalizedMarkdownText), id: \.self) { suggestion in
                                Label(suggestion, systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Next Session", systemImage: "figure.run")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(normalizedMarkdownText(aiInsight.nextWorkoutSuggestion))
                            .font(.bodyRegular)
                            .foregroundStyle(.primary)
                    }
                    .padding()
                    .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    Text(hasAIKey
                         ? "Tap “Load Insights” to fetch AI coaching feedback for this workout."
                         : "Add your AI API key in Settings to load cloud AI workout analysis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func markdownParagraphs(from text: String) -> [String] {
        let cleanedLines = text
            .split(separator: "\n")
            .map { normalizedMarkdownText(String($0)) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleanedLines.isEmpty ? [normalizedMarkdownText(text)] : cleanedLines
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

    @MainActor
    private func loadAIInsight() async {
        guard !isLoadingAIInsight else { return }
        guard hasAIKey else {
            aiInsight = nil
            return
        }
        isLoadingAIInsight = true
        defer { isLoadingAIInsight = false }

        let historySlice = Array(recentHistory.prefix(8))
        aiInsight = await container.aiCoachService.evaluateWithProvider(
            workout: workout,
            recentHistory: historySlice,
            profile: profiles.first,
            provider: appSettings.aiProvider,
            apiKey: appSettings.aiAPIKey,
            modelOverride: appSettings.aiModelOverride,
            unitPreference: appSettings.unitPreference
        )
    }

    private var hasAIKey: Bool {
        !appSettings.aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Split pace chart

    private var splitPaceChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SPLIT PACES").font(.sectionHeader).foregroundStyle(.secondary)
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
    }

    // MARK: Split HR chart

    private var splitHRChart: some View {
        let hrSplits = workout.splits.filter { $0.heartRate != nil }
        return VStack(alignment: .leading, spacing: 8) {
            Text("HEART RATE BY SPLIT").font(.sectionHeader).foregroundStyle(.secondary)
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
            Text("ELEVATION BY SPLIT").font(.sectionHeader).foregroundStyle(.secondary)
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
            Text("SPLITS").font(.sectionHeader).foregroundStyle(.secondary)
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
        if let scheduled = matchedScheduled, let targetRange = scheduled.targetPaceRange {
            let actual = workout.averagePaceSecondsPerKm
            let status = paceStatus(actual: actual, target: targetRange)

            VStack(alignment: .leading, spacing: 10) {
                Text("PERFORMANCE")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target pace")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(
                            "\(targetRange.lowerBound.paceString(unit: appSettings.unitPreference))" +
                            " – " +
                            "\(targetRange.upperBound.paceString(unit: appSettings.unitPreference))"
                        )
                        .font(.bodyStrong)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Your pace")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(actual.paceString(unit: appSettings.unitPreference))
                            .font(.bodyStrong)
                    }
                }

                Label(status.label, systemImage: status.icon)
                    .font(.bodyStrong)
                    .foregroundStyle(status.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
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
