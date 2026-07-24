import SwiftUI
import MapKit
import Charts
import SwiftData

// This screen is a large, pre-existing composite view (run map, charts, splits, AI
// coach) that already exceeds SwiftLint's file_length limit. Disable the rule here
// rather than force a risky split; a proper decomposition is tracked separately.
// swiftlint:disable file_length

struct RunSummaryView: View {
    let workout: RunWorkout

    @Environment(AppSettings.self) private var appSettings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainer) private var container
    @Query private var scheduledWorkouts: [ScheduledWorkout]
    @Query(sort: \RunWorkout.date, order: .reverse) private var allWorkouts: [RunWorkout]
    @Query private var profiles: [UserProfile]
    @Query(
        filter: #Predicate<TrainingPlan> { $0.isActive },
        sort: \TrainingPlan.createdAt, order: .reverse
    )
    private var activePlans: [TrainingPlan]

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
    @State private var isApplyingNextSessionFeedback = false
    @State private var nextSessionUpdateMessage: String?
    @State private var coachChatRequest: AICoachChatRequest?
    @State private var zoneSlices: [HRZoneSlice] = []

    private var matchedScheduled: ScheduledWorkout? {
        scheduledWorkouts.first { $0.completedWorkout?.id == workout.id }
    }

    private var planForNextSessionUpdate: TrainingPlan? {
        matchedScheduled?.week?.plan
            ?? workout.scheduledWorkout?.week?.plan
            ?? activePlans.first
    }

    private var estimatedVO2Max: Double? {
        ProgressStatsService.estimatedVDOT(for: workout)
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

    /// Lowercase label for the unit each split bucket represents ("km" / "mi"), read from the
    /// run's stored `splitUnit` so a mile-bucketed run reads "mi" while legacy km runs read "km".
    private var splitLabel: String { workout.splitUnit.distanceLabel }
    /// Uppercase form used in chart/table headers ("KM" / "MI").
    private var splitLabelUpper: String { workout.splitUnit.splitLabel }

    /// The runner's max HR (explicit or age-estimated) needed to compute HR zones.
    private var maxHeartRate: Double? {
        profiles.first?.effectiveMaxHeartRate.map(Double.init)
    }

    /// Loads the time-in-zone breakdown for this run: uses persisted HR samples when present,
    /// otherwise backfills from HealthKit on demand for older imported runs (A6). No-op when the
    /// runner has no max HR configured.
    private func loadHeartRateZones() async {
        guard let maxHR = maxHeartRate else { zoneSlices = []; return }
        var samples = workout.heartRateSamples
        if samples.isEmpty, let hkID = workout.healthKitWorkoutID {
            samples = await container.healthKitRepository.fetchHeartRateSamples(forWorkoutID: hkID)
            if !samples.isEmpty {
                workout.heartRateSamples = samples   // cache so we don't re-fetch next time
                try? context.save()
            }
        }
        zoneSlices = HeartRateZoneService.timeInZones(
            bpmSamples: samples,
            totalSeconds: workout.durationSeconds,
            maxHR: maxHR
        )
    }

    private var recentHistory: [RunWorkout] {
        allWorkouts.filter { $0.id != workout.id }
    }

    private var tempoInsights: TempoInsights? {
        guard displayType == .tempo, let profile = profiles.first else { return nil }
        return WorkoutAnalyticsService().tempoInsights(
            for: workout,
            history: recentHistory,
            profile: profile
        )
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
                aiCoachAccessCard
                statsGrid
                paceInsightsSection
                weatherSection
                plannedWorkoutSection
                aiCoachSection
                if !workout.splits.isEmpty {
                    splitPaceChart
                    if hasSplitHR { splitHRChart }
                    if hasSplitElevation { splitElevationChart }
                    splitsTable
                }
                if !zoneSlices.isEmpty, zoneSlices.contains(where: { $0.seconds > 0 }) {
                    heartRateZoneSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .task(id: workout.id) { await loadHeartRateZones() }
        .background(Color.surfacePrimary.ignoresSafeArea())
        .navigationTitle(displayType.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete workout")
            }
        }
        .sheet(isPresented: $showAssociateSheet) {
            AssociateWorkoutSheet(workout: workout)
        }
        .sheet(item: $coachChatRequest) { request in
            AICoachChatView(workout: workout, initialPrompt: request.prompt)
        }
        .confirmationDialog("Delete this workout?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                // Repository owns tombstone creation + scheduled-day reset (isCompleted).
                try? container.workoutRepository.delete(workout)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This workout will be permanently removed.")
        }
        .onAppear {
            if aiInsight == nil {
                aiInsight = workout.cachedAIInsight
            }
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

    // MARK: Top AI Coach access

    private var aiCoachAccessCard: some View {
        Button {
            handleTopCoachCardTap()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white)
                        .frame(width: 42, height: 42)
                        .shadow(color: Color.brand.opacity(0.20), radius: 10, y: 4)
                    if isLoadingAIInsight {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.brand)
                    } else {
                        SparkleShape()
                            .fill(Color.brand)
                            .frame(width: 18, height: 18)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("AI COACH")
                            .font(.system(size: 10.5, weight: .heavy))
                            .kerning(1.4)
                            .foregroundStyle(.brand)
                        Circle()
                            .fill(Color.brand)
                            .frame(width: 5, height: 5)
                        Text(topCoachBadgeText)
                            .font(.system(size: 10, weight: .bold))
                            .kerning(0.6)
                            .foregroundStyle(.brand)
                    }

                    Text(topCoachHeadline)
                        .font(.system(size: 14, weight: .bold))
                        .kerning(-0.2)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let confidence = topCoachConfidence {
                        HStack(spacing: 6) {
                            Capsule()
                                .fill(Color.brand.opacity(0.18))
                                .frame(width: 50, height: 3)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.brand)
                                        .frame(width: 50 * CGFloat(confidence) / 100, height: 3)
                                }
                            Text("\(confidence)% conf.")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.brand)
                        }
                    }
                }

                Spacer(minLength: 8)
                StrideIcon(name: .chevronRight, size: 14, color: .brand, strokeWeight: 2.4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color.brand.opacity(0.20), Color.brand.opacity(0.075)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.brand.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("AI Coach")
        .accessibilityHint(topCoachAccessibilityHint)
    }

    private var topCoachBadgeText: String {
        guard appSettings.aiInsightsEnabled else { return "SETUP" }
        if isLoadingAIInsight { return "LOADING" }
        return aiInsight?.apiReady == true ? "READY" : "NEW"
    }

    private var topCoachHeadline: String {
        if let aiInsight, aiInsight.apiReady {
            let headline = normalizedMarkdownText(aiInsight.headline)
            return headline.isEmpty ? "Analysis ready. Ask a follow-up." : headline
        }
        if appSettings.aiInsightsEnabled, hasAIKey {
            return "Get a coaching read, evidence, and next-session actions."
        }
        return "Turn on AI Coach to ask follow-ups about this run."
    }

    private var topCoachConfidence: Int? {
        guard let aiInsight, aiInsight.apiReady else { return nil }
        return aiInsight.confidence
    }

    private var topCoachAccessibilityHint: String {
        if aiInsight?.apiReady == true {
            return "Opens AI Coach chat for this workout."
        }
        return "Loads AI Coach analysis for this workout."
    }

    @MainActor
    private func handleTopCoachCardTap() {
        if aiInsight?.apiReady == true {
            coachChatRequest = AICoachChatRequest(prompt: "Walk me through your coaching read for this run.")
            return
        }

        guard appSettings.aiInsightsEnabled, hasAIKey else {
            coachChatRequest = AICoachChatRequest(prompt: "What should I learn from this run?")
            return
        }

        Task {
            await loadAIInsight()
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

    // MARK: Pace insights section (tempo runs)

    @ViewBuilder
    private var paceInsightsSection: some View {
        if let insights = tempoInsights {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: "Pace Insights")

                VStack(spacing: 10) {
                    tempoInsightPaceRow(insights)
                    if insights.derivedVDOT != nil || insights.previousVDOT != nil {
                        Divider().padding(.horizontal, -2)
                        tempoInsightVDOTRow(insights)
                    }
                    if let consistency = insights.splitConsistencySeconds {
                        Divider().padding(.horizontal, -2)
                        tempoInsightConsistencyRow(consistency)
                    }
                }
                .padding(14)
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))

                if insights.recentTempoCount == 0 {
                    Text("This is your first tempo run — keep it up to track pace trends.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private func tempoInsightPaceRow(_ insights: TempoInsights) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TEMPO PACE")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(insights.achievedPaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .kerning(-0.5)

                if let prev = insights.previousBestTempoSecondsPerKm {
                    let delta = prev - insights.achievedPaceSecondsPerKm
                    let isNew = delta > 1
                    HStack(spacing: 4) {
                        Image(systemName: isNew ? "arrow.up.circle.fill" : (delta < -1 ? "arrow.down.circle.fill" : "minus.circle.fill"))
                            .font(.system(size: 10))
                        Text(isNew
                             ? "New best"
                             : (delta < -1
                                ? "\(Int(abs(delta)))s slower than best"
                                : "Matches best"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(isNew ? Color.success : (delta < -1 ? Color.destructive : Color.secondary))
                }
            }
            Spacer()
            if let target = insights.targetThresholdSecondsPerKm {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("TARGET")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    Text(target.paceString(unit: appSettings.unitPreference))
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    tempoTargetStatusChip(actual: insights.achievedPaceSecondsPerKm, target: target)
                }
            }
        }
    }

    private func tempoTargetStatusChip(actual: Double, target: Double) -> some View {
        let margin = target * 0.04
        let (label, icon, color): (String, String, Color) = {
            if actual <= target - margin {
                return ("Exceeded", "bolt.fill", .brand)
            } else if actual <= target + margin {
                return ("On target", "checkmark.circle.fill", .success)
            } else if actual <= target + margin * 3 {
                return ("Slightly slow", "exclamationmark.circle.fill", .warning)
            } else {
                return ("Off target", "tortoise.fill", .destructive)
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(label).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
    }

    private func tempoInsightVDOTRow(_ insights: TempoInsights) -> some View {
        HStack(spacing: 0) {
            if let vdot = insights.derivedVDOT {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VDOT THIS RUN")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", vdot))
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        if let prev = insights.previousVDOT {
                            let delta = vdot - prev
                            Text(delta >= 0
                                 ? String(format: "+%.1f", delta)
                                 : String(format: "%.1f", delta))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(delta >= 0.3 ? Color.success : (delta <= -0.3 ? Color.destructive : Color.secondary))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let prev = insights.previousVDOT {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("PREV VDOT")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f", prev))
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func tempoInsightConsistencyRow(_ stdDevSeconds: Double) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("SPLIT CONSISTENCY")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "±%.0fs/km", stdDevSeconds))
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    Text("std dev")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            let (label, color): (String, Color) = {
                if stdDevSeconds <= 5 { return ("Excellent", .success) }
                if stdDevSeconds <= 12 { return ("Good", .brand) }
                if stdDevSeconds <= 20 { return ("Variable", .warning) }
                return ("Uneven", .destructive)
            }()
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(color.opacity(0.1), in: Capsule())
        }
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
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(.brand)
                Spacer()
                confidenceChip(insight.confidence)
            }

            Text(markdownText(insight.headline))
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

    private var aiAskCoachCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ASK COACH")
                .font(.system(size: 11, weight: .bold))
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
                                .font(.system(size: 12.5, weight: .semibold))
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
                        .font(.system(size: 13.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
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
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await applyNextSessionFeedback(insight) }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
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
                            .font(.system(size: 10, weight: .bold))
                            .kerning(0.8)
                            .foregroundStyle(.secondary)
                        Text(markdownText(insight.nextWorkoutSuggestion))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let rationale = insight.nextWorkoutRationale?.trimmingCharacters(in: .whitespacesAndNewlines), !rationale.isEmpty {
                            Text(markdownText(rationale))
                                .font(.system(size: 12))
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(nextSessionUpdateMessage.hasPrefix("Updated") ? Color.success : Color.secondary)
                    .padding(.horizontal, 2)
            }
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

            Text(markdownText(fullAnalysisText(for: insight)))
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
            Text(hasAIKey ? "Ready for analysis" : "AI Coach is off")
                .font(.system(size: 15, weight: .bold))
            Text(hasAIKey
                 ? "Tap Load to fetch on-device AI coaching feedback for this workout."
                 : "Turn on AI Coach in Settings to load on-device workout analysis.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func aiUnavailableCard(_ insight: AICoachInsight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(markdownText(insight.headline))
                .font(.system(size: 15, weight: .bold))
            Text(markdownText(insight.summary))
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

    private func markdownText(_ text: String) -> AttributedString {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let attributed = try? AttributedString(
            markdown: trimmed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(normalizedMarkdownText(text))
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
                        Text(Self.markdownText(action.title))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(cleaned(action.priority).uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(priorityColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(priorityColor.opacity(0.12), in: Capsule())
                    }

                    Text(Self.markdownText(action.detail))
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

        private static func markdownText(_ text: String) -> AttributedString {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let attributed = try? AttributedString(
                markdown: trimmed,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                return attributed
            }
            var output = trimmed
            ["**", "__", "`", "###", "##", "#", ">", "_"].forEach {
                output = output.replacingOccurrences(of: $0, with: "")
            }
            return AttributedString(output)
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
        let result = await container.aiCoachService.evaluateWithProvider(
            workout: workout,
            recentHistory: historySlice,
            profile: profiles.first,
            provider: appSettings.aiProvider,
            unitPreference: appSettings.unitPreference,
            onChunk: { chunk in
                Task { @MainActor in
                    appendInsightStreamChunk(chunk)
                }
            }
        )
        aiInsight = result
        if result.apiReady {
            workout.cachedAIInsight = result
            try? context.save()
        }
    }

    private var canApplyNextSessionFeedback: Bool {
        hasAIKey && profiles.first != nil && nextWorkoutForFeedback() != nil
    }

    @MainActor
    private func applyNextSessionFeedback(_ insight: AICoachInsight) async {
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
            recentHistory: Array(allWorkouts.prefix(50)),
            profile: profile,
            provider: appSettings.aiProvider,
            unitPreference: appSettings.unitPreference,
            coachFeedback: coachFeedbackPromptText(insight: insight)
        ) else {
            nextSessionUpdateMessage = "The coach feedback could not be applied. Try refreshing the AI analysis."
            return
        }

        apply(adapted, to: nextWorkout)
        removeDuplicateFutureRuns(preserving: nextWorkout)
        try? context.save()

        if let plan = nextWorkout.week?.plan {
            try? await container.healthKitRepository.removeWorkoutPlans(for: plan)
            try? await container.healthKitRepository.syncWorkoutPlans(for: plan, unitPreference: appSettings.unitPreference)
        }

        nextSessionUpdateMessage = "Updated \(workoutLabel(nextWorkout)) in your plan."
    }

    private func nextWorkoutForFeedback() -> ScheduledWorkout? {
        guard let plan = planForNextSessionUpdate else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let completedDate = matchedScheduled?.scheduledDate
            ?? workout.scheduledWorkout?.scheduledDate
            ?? workout.date

        let weeks = plan.weeks ?? []
        let workouts = weeks.flatMap { $0.workouts ?? [] }
        let candidates = workouts.filter { scheduled in
            guard !scheduled.isCompleted else { return false }
            guard scheduled.scheduledDate >= today else { return false }
            guard scheduled.scheduledDate > completedDate else { return false }

            switch scheduled.workoutType {
            case .easy, .tempo, .interval, .longRun:
                return true
            case .race, .rest, .crossTraining, .strength:
                return false
            }
        }

        return candidates.sorted { lhs, rhs in
            lhs.scheduledDate < rhs.scheduledDate
        }.first
    }

    /// Coach feedback as plain prompt text. Passed to the adaptation request as a
    /// string instead of seeding a temporary ScheduledWorkout: relating an unmanaged
    /// model to a persisted week auto-inserts it, leaving a phantom duplicate in the plan.
    private func coachFeedbackPromptText(insight: AICoachInsight) -> String {
        [
            "AI Coach feedback from completed \(displayType.displayName.lowercased()) on \(workout.date.formatted(date: .abbreviated, time: .omitted)):",
            normalizedMarkdownText(insight.headline),
            normalizedMarkdownText(insight.summary),
            "Next session suggestion: \(normalizedMarkdownText(insight.nextWorkoutSuggestion))",
            insight.nextWorkoutRationale.map { "Rationale: \(normalizedMarkdownText($0))" }
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func apply(_ adapted: ScheduledWorkout, to scheduled: ScheduledWorkout) {
        scheduled.workoutType = adapted.workoutType
        scheduled.workoutStructure = adapted.workoutStructure
        scheduled.targetDistanceMeters = adapted.targetDistanceMeters
        scheduled.targetPaceLowerBound = adapted.targetPaceLowerBound
        scheduled.targetPaceUpperBound = adapted.targetPaceUpperBound
        scheduled.notes = adapted.notes
        scheduled.intervals = adapted.intervals
        scheduled.healthKitPlanID = nil
    }

    private func removeDuplicateFutureRuns(preserving keeper: ScheduledWorkout) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let planID = keeper.week?.plan?.id

        let futureRuns = scheduledWorkouts.filter { scheduled in
            guard let planID else { return false }
            return scheduled.week?.plan?.id == planID
                && !scheduled.isCompleted
                && scheduled.completedWorkout == nil
                && scheduled.completedStrengthWorkout == nil
                && isRunWorkout(scheduled.workoutType)
                && scheduled.scheduledDate >= today
        }

        let runsByDay = Dictionary(grouping: futureRuns) { scheduled in
            calendar.startOfDay(for: scheduled.scheduledDate)
        }

        let duplicates = runsByDay.values.flatMap { sameDayRuns -> [ScheduledWorkout] in
            guard sameDayRuns.count > 1 else { return [] }
            let keeperForDay = preferredRun(from: sameDayRuns, preserving: keeper.id)
            return sameDayRuns.filter { $0.id != keeperForDay.id }
        }

        for duplicate in duplicates {
            duplicate.week?.workouts?.removeAll { $0.id == duplicate.id }
            context.delete(duplicate)
        }
    }

    private func preferredRun(
        from workouts: [ScheduledWorkout],
        preserving preservedID: UUID
    ) -> ScheduledWorkout {
        if let preserved = workouts.first(where: { $0.id == preservedID }) {
            return preserved
        }

        return workouts.sorted { lhs, rhs in
            let lhsPriority = runPriority(lhs.workoutType)
            let rhsPriority = runPriority(rhs.workoutType)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.scheduledDate < rhs.scheduledDate
        }.first ?? workouts[0]
    }

    private func runPriority(_ type: WorkoutType) -> Int {
        switch type {
        case .race:
            return 0
        case .interval, .tempo:
            return 1
        case .longRun:
            return 2
        case .easy:
            return 3
        case .rest, .crossTraining, .strength:
            return 4
        }
    }

    private func isRunWorkout(_ type: WorkoutType) -> Bool {
        switch type {
        case .easy, .tempo, .interval, .longRun, .race:
            return true
        case .rest, .crossTraining, .strength:
            return false
        }
    }

    private func workoutLabel(_ workout: ScheduledWorkout) -> String {
        let date = workout.scheduledDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(date) \(workout.workoutType.displayName)"
    }

    @MainActor
    private func appendInsightStreamChunk(_ chunk: String) {
        aiStreamBuffer += chunk
    }

    private var hasAIKey: Bool {
        // Apple's on-device / Private Cloud Compute models need no key.
        appSettings.hasAICredentials
    }

    private var postRunCoachPrompts: [String] {
        [
            "Why was my HR so high?",
            "Should I rest tomorrow?",
            "How does this compare to last week?",
            "Adjust this week"
        ]
    }

    // MARK: Split pace chart

    // Splits are always recorded per kilometer (`WorkoutTrackerService` buckets
    // every 1000 m), so the bucket axis, tooltips, and table column are labelled
    // "km" regardless of the user's distance preference. Labelling a 10 km run's
    // ten buckets "MI 1 … MI 10" implied a 10-mile run. The pace and elevation
    // values shown inside each bucket are still converted to the preferred unit.
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
                        x: .value("km", split.kilometer),
                        y: .value("Pace", split.paceSecondsPerKm)
                    )
                    .foregroundStyle(selectedSplitPaceKm == split.kilometer ? Color.brand : Color.brand.opacity(selectedSplitPaceKm == nil ? 1.0 : 0.5))
                }
                if let km = selectedSplitPaceKm, let split = split(forKm: km) {
                    RuleMark(x: .value("km", km))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(splitLabel) \(km)")
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
                        x: .value("km", split.kilometer),
                        y: .value("bpm", split.heartRate ?? 0)
                    )
                    .foregroundStyle(.zoneInterval)
                    PointMark(
                        x: .value("km", split.kilometer),
                        y: .value("bpm", split.heartRate ?? 0)
                    )
                    .foregroundStyle(.zoneInterval)
                    .symbolSize(selectedSplitHRKm == split.kilometer ? 80 : 36)
                }
                if let km = selectedSplitHRKm, let split = split(forKm: km), let hr = split.heartRate {
                    RuleMark(x: .value("km", km))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(splitLabel) \(km)")
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
                        x: .value("km", split.kilometer),
                        y: .value(appSettings.unitPreference.elevationLabel, gain)
                    )
                    .foregroundStyle(
                        (gain >= 0 ? Color.success : Color.destructive)
                            .opacity(selectedSplitElevKm == nil || selectedSplitElevKm == split.kilometer ? 1.0 : 0.5)
                    )
                }
                if let km = selectedSplitElevKm, let split = split(forKm: km) {
                    let gain = split.elevationGainMeters.elevationValue(unit: appSettings.unitPreference)
                    RuleMark(x: .value("km", km))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(splitLabel) \(km)")
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
                Text(splitLabelUpper)
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

    // MARK: Heart-rate zone section

    private var heartRateZoneSection: some View {
        let total = zoneSlices.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 12) {
            Text("TIME IN HEART-RATE ZONES")
                .font(.sectionHeader).foregroundStyle(.secondary).padding(.horizontal, 4)
            // Stacked proportion bar.
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(zoneSlices) { slice in
                        if slice.seconds > 0 {
                            slice.zone.color
                                .frame(width: max(3, geo.size.width * CGFloat(slice.seconds / max(total, 1))))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            // Per-zone rows, hardest zone first.
            VStack(spacing: 8) {
                ForEach(zoneSlices.reversed()) { slice in
                    zoneRow(slice, total: total)
                }
            }
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func zoneRow(_ slice: HRZoneSlice, total: Double) -> some View {
        let pct = total > 0 ? slice.seconds / total : 0
        let bounds = maxHeartRate.map { HeartRateZoneService.bounds(for: slice.zone, maxHR: $0) }
        return HStack(spacing: 10) {
            Circle().fill(slice.zone.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(slice.zone.displayTitle).font(.caption).bold()
                if let bounds {
                    Text("\(bounds.lower)–\(bounds.upper) bpm")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(slice.seconds.durationString).font(.caption).monospacedDigit()
            Text("\(Int((pct * 100).rounded()))%")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slice.zone.displayTitle), \(Int((pct * 100).rounded())) percent")
    }

    // MARK: Planned Workout Section

    @ViewBuilder
    private var plannedWorkoutSection: some View {
        if let scheduled = matchedScheduled {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: "Planned Workout")

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(scheduled.workoutType.color)
                            .frame(width: 8, height: 8)
                        Text(scheduled.workoutType.displayName)
                            .font(.system(size: 15, weight: .bold))
                        Spacer()
                        Text(scheduled.scheduledDate.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if scheduled.targetDistanceMeters != nil || scheduled.targetPaceRange != nil {
                        HStack(spacing: 8) {
                            if let dist = scheduled.targetDistanceMeters {
                                let converted = appSettings.unitPreference == .imperial ? dist / 1_609.344 : dist / 1_000
                                plannedChip(icon: "arrow.right", text: String(format: "%.1f %@", converted, appSettings.unitPreference.distanceLabel))
                            }
                            if let range = scheduled.targetPaceRange {
                                let lo = range.lowerBound.paceString(unit: appSettings.unitPreference)
                                    .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: "")
                                let hi = range.upperBound.paceString(unit: appSettings.unitPreference)
                                plannedChip(icon: "speedometer", text: "\(lo)–\(hi)")
                            }
                        }
                    }

                    if let notes = scheduled.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let hasComparison = scheduled.targetDistanceMeters != nil || scheduled.targetPaceRange != nil
                    if hasComparison {
                        Divider().padding(.vertical, 2)

                        if let targetDist = scheduled.targetDistanceMeters {
                            let converted = appSettings.unitPreference == .imperial ? targetDist / 1_609.344 : targetDist / 1_000
                            planComparisonRow(
                                label: "Distance",
                                planned: String(format: "%.2f %@", converted, appSettings.unitPreference.distanceLabel),
                                actual: "\(titleMetric.value) \(titleMetric.unit)",
                                status: distanceStatus(actual: workout.distanceMeters, target: targetDist)
                            )
                        }

                        if let range = scheduled.targetPaceRange {
                            let actual = workout.averagePaceSecondsPerKm
                            let lo = range.lowerBound.paceString(unit: appSettings.unitPreference)
                                .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: "")
                            let hi = range.upperBound.paceString(unit: appSettings.unitPreference)
                            planComparisonRow(
                                label: "Avg Pace",
                                planned: "\(lo)–\(hi)",
                                actual: actual.paceString(unit: appSettings.unitPreference),
                                status: paceStatus(actual: actual, target: range)
                            )
                        }
                    }
                }
                .padding(14)
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
            }
        } else if let avg = workout.averageHeartRate, avg >= 155 {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.warning)
                        .frame(width: 24, height: 24)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Effort higher than expected")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.warning)
                    Text("HR averaged \(Int(avg)) bpm for this \(workout.workoutType.displayName.lowercased()) effort.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.warning.opacity(0.22), lineWidth: 0.5))
        }
    }

    private func plannedChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.surfaceTertiary, in: Capsule())
    }

    private func planComparisonRow(label: String, planned: String, actual: String, status: PaceStatus) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)
            Text(planned)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(actual)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Image(systemName: status.icon)
                    .font(.system(size: 10, weight: .bold))
                Text(status.label)
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.1), in: Capsule())
        }
    }

    private func distanceStatus(actual: Double, target: Double) -> PaceStatus {
        let ratio = actual / target
        if ratio > 1.05 {
            return PaceStatus(label: "Exceeded", icon: "arrow.up.circle.fill", color: .brand)
        } else if ratio >= 0.97 {
            return PaceStatus(label: "Completed", icon: "checkmark.circle.fill", color: .success)
        } else if ratio >= 0.90 {
            return PaceStatus(label: "Close", icon: "minus.circle.fill", color: .warning)
        } else {
            return PaceStatus(label: "Short", icon: "arrow.down.circle.fill", color: .destructive)
        }
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

    private struct AICoachChatRequest: Identifiable {
        let id = UUID()
        let prompt: String?
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
                        Text(Self.markdownText(title))
                            .font(.system(size: 15, weight: .bold))
                            .kerning(-0.2)
                    }
                    Text(Self.markdownText(detail))
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

        private static func markdownText(_ text: String) -> AttributedString {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let attributed = try? AttributedString(
                markdown: trimmed,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                return attributed
            }
            var output = trimmed
            ["**", "__", "`", "###", "##", "#", ">", "_"].forEach {
                output = output.replacingOccurrences(of: $0, with: "")
            }
            return AttributedString(output)
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
