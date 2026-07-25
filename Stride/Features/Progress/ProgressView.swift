import SwiftUI
import Charts
import SwiftData

struct ProgressDashboardView: View {
    @Query(sort: [SortDescriptor(\RunWorkout.date)])
    private var workouts: [RunWorkout]

    @Query private var profiles: [UserProfile]
    private var profile: UserProfile? { profiles.first }

    @Environment(AppSettings.self) private var appSettings
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var context
    @State private var selectedRange: ChartRange = .threeMonths

    /// HealthKit ids already asked for HR samples this session, so a run whose source
    /// workout is gone isn't re-queried on every period change (N25).
    @State private var attemptedBackfillIDs: Set<String> = []
    @State private var isBackfillingHeartRate = false

    @State private var selectedVolumeDate: Date? = nil
    @State private var selectedPaceDate: Date? = nil
    @State private var selectedHRDate: Date? = nil
    @State private var selectedElevationDate: Date? = nil
    @State private var selectedVO2Date: Date? = nil

    @Namespace private var rangeNamespace
    @Namespace private var tabNamespace
    @State private var progressAppeared = false
    @State private var selectedTab: ProgressTab = .stats

    enum ProgressTab: String, CaseIterable {
        case stats    = "Stats"
        case insights = "Insights"
        case medals   = "Achievements"
    }

    enum ChartRange: String, CaseIterable {
        case month = "1M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case year = "1Y"

        var days: Int {
            switch self {
            case .month: return 30
            case .threeMonths: return 90
            case .sixMonths: return 180
            case .year: return 365
            }
        }
    }

    private struct VO2Point: Identifiable {
        let id = UUID()
        let date: Date
        let vdot: Double
    }

    private var filteredWorkouts: [RunWorkout] {
        let cutoff = Date().addingTimeInterval(-Double(selectedRange.days) * 86_400)
        return workouts.filter { $0.date >= cutoff }
    }

    private var vo2Points: [VO2Point] {
        filteredWorkouts.compactMap { w in
            guard let v = ProgressStatsService.estimatedVDOT(for: w) else { return nil }
            return VO2Point(date: w.date, vdot: v)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabPicker
                if selectedTab == .insights {
                    RaceInsightsView()
                } else if selectedTab == .stats {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            summaryHeader
                                .opacity(progressAppeared ? 1 : 0)
                                .scaleEffect(progressAppeared ? 1 : 0.94, anchor: .top)
                                .adaptiveAnimation(AppAnimation.entrance.delay(0.05), value: progressAppeared)
                            rangePicker
                                .opacity(progressAppeared ? 1 : 0)
                                .offset(y: progressAppeared ? 0 : 10)
                                .adaptiveAnimation(AppAnimation.entrance.delay(0.10), value: progressAppeared)
                            weeklyVolumeChart
                                .opacity(progressAppeared ? 1 : 0)
                                .offset(y: progressAppeared ? 0 : 18)
                                .adaptiveAnimation(AppAnimation.entrance.delay(0.15), value: progressAppeared)
                            paceProgressChart
                                .opacity(progressAppeared ? 1 : 0)
                                .offset(y: progressAppeared ? 0 : 18)
                                .adaptiveAnimation(AppAnimation.entrance.delay(0.20), value: progressAppeared)
                            heartRateTrendChart
                                .opacity(progressAppeared ? 1 : 0)
                                .offset(y: progressAppeared ? 0 : 18)
                                .adaptiveAnimation(AppAnimation.entrance.delay(0.25), value: progressAppeared)
                            heartRateZoneChart
                                .opacity(progressAppeared ? 1 : 0)
                                .offset(y: progressAppeared ? 0 : 18)
                                .adaptiveAnimation(AppAnimation.entrance.delay(0.28), value: progressAppeared)
                            elevationTrendChart
                                .opacity(progressAppeared ? 1 : 0)
                                .offset(y: progressAppeared ? 0 : 18)
                                .adaptiveAnimation(AppAnimation.entrance.delay(0.30), value: progressAppeared)
                            vo2MaxTrendChart
                                .opacity(progressAppeared ? 1 : 0)
                                .offset(y: progressAppeared ? 0 : 18)
                                .adaptiveAnimation(AppAnimation.entrance.delay(0.35), value: progressAppeared)
                            periodSummaryCard
                                .opacity(progressAppeared ? 1 : 0)
                                .offset(y: progressAppeared ? 0 : 18)
                                .adaptiveAnimation(AppAnimation.entrance.delay(0.40), value: progressAppeared)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .task { progressAppeared = true }
                        .task(id: selectedRange) { await backfillHeartRateSamples() }
                    }
                } else {
                    AchievementsView()
                }
            }
            .background(Color.surfacePrimary)
            .navigationTitle("Progress")
        }
        .onChange(of: selectedRange) {
            selectedVolumeDate = nil
            selectedPaceDate = nil
            selectedHRDate = nil
            selectedElevationDate = nil
            selectedVO2Date = nil
        }
        .onChange(of: selectedTab) {
            if selectedTab == .stats {
                progressAppeared = false
                Task { @MainActor in progressAppeared = true }
            }
        }
    }

    // MARK: - Summary header

    private var summaryHeader: some View {
        HStack(spacing: 0) {
            summaryStatCell(
                value: "\(filteredWorkouts.count)",
                label: "Runs"
            )
            Divider().frame(height: 40)
            summaryStatCell(
                value: filteredWorkouts.reduce(0) { $0 + $1.distanceMeters }
                    .distanceString(unit: appSettings.unitPreference),
                label: "Distance"
            )
            Divider().frame(height: 40)
            summaryStatCell(
                value: vo2Points.last.map { String(format: "%.0f", $0.vdot) } ?? "--",
                label: "VDOT"
            )
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func summaryStatCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.captionStrong)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        HStack(spacing: 4) {
            ForEach(ChartRange.allCases, id: \.self) { range in
                Button {
                    withAnimation(AppAnimation.bouncy) { selectedRange = range }
                } label: {
                    Text(range.rawValue)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if selectedRange == range {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.brand)
                                    .matchedGeometryEffect(id: "rangePill", in: rangeNamespace)
                            }
                        }
                        .foregroundStyle(selectedRange == range ? .white : .secondary)
                        .adaptiveAnimation(AppAnimation.bouncy, value: selectedRange)
                }
                .buttonStyle(BouncyButtonStyle())
            }
        }
        .padding(4)
        .background(Color.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(ProgressTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(AppAnimation.bouncy) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.brand)
                                    .matchedGeometryEffect(id: "tabPill", in: tabNamespace)
                            }
                        }
                        .foregroundStyle(selectedTab == tab ? .white : .secondary)
                        .adaptiveAnimation(AppAnimation.bouncy, value: selectedTab)
                }
                .buttonStyle(BouncyButtonStyle())
            }
        }
        .padding(4)
        .background(Color.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.sm)
        .padding(.bottom, AppSpacing.xs)
    }

    // MARK: - Chart card wrapper

    private func chartCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.sectionHeader)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Weekly volume chart

    private var weeklyVolumeChart: some View {
        chartCard("WEEKLY VOLUME") {
            Chart {
                ForEach(weeklyBuckets, id: \.week) { bucket in
                    BarMark(
                        x: .value("Week", bucket.week, unit: .weekOfYear),
                        y: .value(appSettings.unitPreference.distanceLabel, bucket.distanceValue)
                    )
                    .foregroundStyle(Color.brand.gradient)
                    .cornerRadius(4)
                }
                if let selected = selectedVolumeDate, let bucket = closestWeekBucket(to: selected) {
                    selectionRule(x: .value("Week", bucket.week)) {
                        tooltipContainer {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bucket.week, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(String(format: "%.1f %@", bucket.distanceValue, appSettings.unitPreference.distanceLabel))
                                    .font(.caption).bold()
                            }
                        }
                    }
                }
            }
            .frame(height: 160)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartXSelection(value: $selectedVolumeDate)
        }
    }

    // MARK: - Pace trend chart

    private var paceProgressChart: some View {
        let paceWorkouts = filteredWorkouts.filter { $0.averagePaceSecondsPerKm > 0 }
        return chartCard("AVERAGE PACE") {
            if paceWorkouts.isEmpty {
                emptyDataPlaceholder("No pace data in this period")
            } else {
                Chart {
                    ForEach(paceWorkouts) { workout in
                        LineMark(
                            x: .value("Date", workout.date),
                            y: .value("sec/km", workout.averagePaceSecondsPerKm)
                        )
                        .foregroundStyle(Color.brand)
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Date", workout.date),
                            y: .value("sec/km", workout.averagePaceSecondsPerKm)
                        )
                        .foregroundStyle(Color.brand)
                        .symbolSize(
                            selectedPaceDate.flatMap { closestWorkout(to: $0, in: paceWorkouts) }?.id == workout.id ? 80 : 36
                        )
                    }
                    if let selected = selectedPaceDate,
                       let workout = closestWorkout(to: selected, in: paceWorkouts) {
                        selectionRule(x: .value("Date", workout.date)) {
                            tooltipContainer {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workout.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                                        .font(.caption).bold()
                                }
                            }
                        }
                    }
                }
                .frame(height: 140)
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
                .chartXSelection(value: $selectedPaceDate)
                Text("Lower is faster")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Heart rate trend chart

    private var heartRateTrendChart: some View {
        let withHR = filteredWorkouts.filter { $0.averageHeartRate != nil }
        return chartCard("AVERAGE HEART RATE") {
            if withHR.isEmpty {
                emptyDataPlaceholder("No heart rate data in this period")
            } else {
                Chart {
                    ForEach(withHR) { workout in
                        LineMark(
                            x: .value("Date", workout.date),
                            y: .value("bpm", workout.averageHeartRate ?? 0)
                        )
                        .foregroundStyle(Color.zoneInterval)
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Date", workout.date),
                            y: .value("bpm", workout.averageHeartRate ?? 0)
                        )
                        .foregroundStyle(Color.zoneInterval)
                        .symbolSize(
                            selectedHRDate.flatMap { closestWorkout(to: $0, in: withHR) }?.id == workout.id ? 80 : 36
                        )
                    }
                    if let selected = selectedHRDate,
                       let workout = closestWorkout(to: selected, in: withHR),
                       let hr = workout.averageHeartRate {
                        selectionRule(x: .value("Date", workout.date)) {
                            tooltipContainer {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workout.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text("\(Int(hr)) bpm")
                                        .font(.caption).bold()
                                }
                            }
                        }
                    }
                }
                .frame(height: 140)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartYAxisLabel("bpm")
                .chartXSelection(value: $selectedHRDate)
            }
        }
    }

    // MARK: - Heart-rate zone distribution

    /// The runner's max HR (explicit or age-estimated), needed to bucket samples into zones.
    private var maxHeartRate: Double? { profile?.effectiveMaxHeartRate.map(Double.init) }

    /// Fills in HR samples for runs in the visible period that don't have any (N25).
    ///
    /// Imports have persisted samples since N9, but runs imported before that carry
    /// none, and this chart only reads persisted samples — so it stayed empty and then
    /// partially filled as the runner happened to open individual runs, which reads as a
    /// bug. Bounded by `HeartRateBackfill.maximumRunsPerPass` and by
    /// `attemptedBackfillIDs`, so a run whose HealthKit source is gone is asked once.
    private func backfillHeartRateSamples() async {
        guard maxHeartRate != nil, !isBackfillingHeartRate else { return }
        let candidates = HeartRateBackfill.runsNeedingSamples(
            in: filteredWorkouts,
            alreadyAttempted: attemptedBackfillIDs
        )
        guard !candidates.isEmpty else { return }

        isBackfillingHeartRate = true
        defer { isBackfillingHeartRate = false }

        var didChange = false
        for run in candidates {
            guard let hkID = run.healthKitWorkoutID else { continue }
            attemptedBackfillIDs.insert(hkID)
            let samples = await container.healthKitRepository.fetchHeartRateSamples(forWorkoutID: hkID)
            guard !samples.isEmpty else { continue }
            run.heartRateSamples = samples
            didChange = true
        }
        if didChange { try? context.save() }
    }

    /// Aggregate time-in-zone across the selected period, from each run's persisted HR samples.
    private var aggregateZoneSlices: [HRZoneSlice] {
        guard let maxHR = maxHeartRate else { return [] }
        let perRun = filteredWorkouts.compactMap { run -> [HRZoneSlice]? in
            let samples = run.heartRateSamples
            guard !samples.isEmpty else { return nil }
            return HeartRateZoneService.timeInZones(
                bpmSamples: samples, totalSeconds: run.durationSeconds, maxHR: maxHR
            )
        }
        return perRun.isEmpty ? [] : HeartRateZoneService.aggregate(perRun)
    }

    private var heartRateZoneChart: some View {
        let slices = aggregateZoneSlices
        let total = slices.reduce(0) { $0 + $1.seconds }
        return chartCard("TIME IN HEART-RATE ZONES") {
            if maxHeartRate == nil {
                emptyDataPlaceholder("Set your max HR in Settings to see heart-rate zones")
            } else if total <= 0 {
                if isBackfillingHeartRate {
                    // Say what's happening rather than claiming there is no data while
                    // it is being fetched (N25).
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading heart-rate data…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    emptyDataPlaceholder("No heart-rate zone data in this period")
                }
            } else {
                VStack(spacing: 10) {
                    Chart(slices) { slice in
                        BarMark(
                            x: .value("Minutes", slice.seconds / 60),
                            y: .value("Zone", slice.zone.shortName)
                        )
                        .foregroundStyle(slice.zone.color)
                        .cornerRadius(4)
                    }
                    .chartYScale(domain: HRZone.allCases.reversed().map(\.shortName))
                    .chartXAxisLabel("minutes")
                    .frame(height: 150)
                    ForEach(slices.reversed()) { slice in
                        let pct = total > 0 ? slice.seconds / total : 0
                        HStack(spacing: 10) {
                            Circle().fill(slice.zone.color).frame(width: 9, height: 9)
                            Text(slice.zone.displayTitle).font(.caption)
                            Spacer()
                            Text(slice.seconds.durationString).font(.caption).monospacedDigit()
                            Text("\(Int((pct * 100).rounded()))%")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Elevation trend chart

    private var elevationTrendChart: some View {
        let withElev = filteredWorkouts.filter { ($0.elevationGainMeters ?? 0) > 0 }
        return chartCard("ELEVATION GAIN") {
            if withElev.isEmpty {
                emptyDataPlaceholder("No elevation data in this period")
            } else {
                Chart {
                    ForEach(withElev) { workout in
                        BarMark(
                            x: .value("Date", workout.date, unit: .day),
                            y: .value(appSettings.unitPreference.elevationLabel,
                                      (workout.elevationGainMeters ?? 0).elevationValue(unit: appSettings.unitPreference))
                        )
                        .foregroundStyle(Color.success.gradient)
                        .cornerRadius(3)
                    }
                    if let selected = selectedElevationDate,
                       let workout = closestWorkout(to: selected, in: withElev),
                       let gain = workout.elevationGainMeters {
                        selectionRule(x: .value("Date", workout.date)) {
                            tooltipContainer {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workout.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(String(format: "+%.0f %@", gain.elevationValue(unit: appSettings.unitPreference), appSettings.unitPreference.elevationLabel))
                                        .font(.caption).bold()
                                }
                            }
                        }
                    }
                }
                .frame(height: 140)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartYAxisLabel(appSettings.unitPreference.elevationLabel)
                .chartXSelection(value: $selectedElevationDate)
            }
        }
    }

    // MARK: - VO₂ max trend chart

    private var vo2MaxTrendChart: some View {
        chartCard("ESTIMATED VO₂ MAX") {
            if vo2Points.isEmpty {
                emptyDataPlaceholder("Not enough run data in this period")
            } else {
                Chart {
                    ForEach(vo2Points) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("VDOT", point.vdot)
                        )
                        .foregroundStyle(Color.brandSecondary)
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("VDOT", point.vdot)
                        )
                        .foregroundStyle(Color.brandSecondary)
                        .symbolSize(
                            selectedVO2Date.flatMap { closestVO2Point(to: $0) }?.id == point.id ? 80 : 36
                        )
                    }
                    if let selected = selectedVO2Date,
                       let point = closestVO2Point(to: selected) {
                        selectionRule(x: .value("Date", point.date)) {
                            tooltipContainer {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(String(format: "%.1f VDOT", point.vdot))
                                        .font(.caption).bold()
                                }
                            }
                        }
                    }
                }
                .frame(height: 140)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartXSelection(value: $selectedVO2Date)
                Text("Higher is better fitness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Period summary card

    private var periodSummaryCard: some View {
        let runs = filteredWorkouts
        let totalMeters = runs.reduce(0) { $0 + $1.distanceMeters }
        let avgPace = ProgressStatsService.distanceWeightedAveragePaceSecondsPerKm(for: runs)
        let hrValues = runs.compactMap(\.averageHeartRate)
        let avgHR: Double? = hrValues.isEmpty ? nil : hrValues.reduce(0, +) / Double(hrValues.count)
        let elevValues = runs.compactMap(\.elevationGainMeters).filter { $0 > 0 }
        let avgElev: Double? = elevValues.isEmpty ? nil : elevValues.reduce(0, +) / Double(elevValues.count)
        let avgVO2: Double? = vo2Points.isEmpty ? nil
            : vo2Points.reduce(0) { $0 + $1.vdot } / Double(vo2Points.count)

        return chartCard("PERIOD SUMMARY") {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                summaryCell(value: "\(runs.count)", label: "Runs")
                summaryCell(value: totalMeters.distanceString(unit: appSettings.unitPreference), label: "Total Distance")
                summaryCell(
                    value: avgPace > 0 ? avgPace.paceString(unit: appSettings.unitPreference) : "--",
                    label: "Avg Pace"
                )
                summaryCell(
                    value: avgHR.map { "\(Int($0)) bpm" } ?? "--",
                    label: "Avg Heart Rate"
                )
                summaryCell(
                    value: avgElev.map { $0.elevationString(unit: appSettings.unitPreference) } ?? "--",
                    label: "Avg Elevation"
                )
                summaryCell(
                    value: avgVO2.map { String(format: "%.1f", $0) } ?? "--",
                    label: "Avg VO₂ Max"
                )
            }
        }
    }

    private func summaryCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.surfaceTertiary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func emptyDataPlaceholder(_ message: String) -> some View {
        HStack(spacing: 10) {
            StrideIcon(name: .chart, size: 16, color: .secondary, strokeWeight: 1.8)
            Text(message)
                .font(.bodyRegular)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 60)
    }

    // MARK: - Selection helpers

    private func closestWorkout(to date: Date, in list: [RunWorkout]) -> RunWorkout? {
        list.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    private func closestWeekBucket(to date: Date) -> WeekBucket? {
        weeklyBuckets.min(by: { abs($0.week.timeIntervalSince(date)) < abs($1.week.timeIntervalSince(date)) })
    }

    private func closestVO2Point(to date: Date) -> VO2Point? {
        vo2Points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    // MARK: - Chart annotation helpers

    @ChartContentBuilder
    private func selectionRule<X: Plottable, Label: View>(
        x: PlottableValue<X>,
        @ViewBuilder label: () -> Label
    ) -> some ChartContent {
        RuleMark(x: x)
            .foregroundStyle(Color.secondary.opacity(0.4))
            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
            .annotation(
                position: .top,
                overflowResolution: .init(x: .fit(to: .chart), y: .disabled),
                content: label
            )
    }

    private func tooltipContainer<C: View>(@ViewBuilder content: () -> C) -> some View {
        content()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.surfacePrimary, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    // MARK: - Weekly buckets

    private struct WeekBucket: Identifiable {
        let id = UUID()
        let week: Date
        let distanceValue: Double
    }

    private var weeklyBuckets: [WeekBucket] {
        var byWeek: [Date: Double] = [:]
        for workout in filteredWorkouts {
            let key = workout.date.startOfWeek
            byWeek[key, default: 0] += workout.distanceMeters
        }
        return byWeek.map { key, meters -> WeekBucket in
            let value: Double
            switch appSettings.unitPreference {
            case .metric: value = meters / 1_000
            case .imperial: value = meters / 1_609.344
            }
            return WeekBucket(week: key, distanceValue: value)
        }
        .sorted { $0.week < $1.week }
    }
}
