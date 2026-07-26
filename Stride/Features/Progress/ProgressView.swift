import SwiftUI
import Charts
import SwiftData

struct ProgressDashboardView: View {
    /// Bounded to the widest range the picker offers, plus a week of slack for the
    /// edge bucket. This screen used to fetch every run ever logged and then filter
    /// in `filteredWorkouts` — on a screen that can never display more than a year,
    /// and that recomputes derived series over whatever it fetched (U9).
    @Query private var workouts: [RunWorkout]

    @Query private var profiles: [UserProfile]
    private var profile: UserProfile? { profiles.first }

    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContainer.self) private var container
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

    init() {
        // A `@Query`'s descriptor is fixed at view-initialisation, so this is where the
        // window has to be set. It is the widest range the picker can ask for plus a
        // week, which keeps the outermost weekly bucket whole.
        let windowDays = ChartRange.year.days + 7
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date())
            ?? Date.distantPast
        _workouts = Query(
            filter: #Predicate<RunWorkout> { $0.date >= cutoff },
            sort: [SortDescriptor(\RunWorkout.date)]
        )
    }

    // The period arithmetic — which runs are in range, what they total, how they bucket
    // by week, and the VDOT series — lives in `ProgressPeriodStats` rather than in these
    // body-evaluated properties (D1). What's left here is the range the runner picked
    // and the unit they read it in.

    private var filteredWorkouts: [RunWorkout] {
        ProgressPeriodStats.runs(in: workouts, withinDays: selectedRange.days)
    }

    private var vo2Points: [ProgressPeriodStats.VDOTSample] {
        ProgressPeriodStats.vdotSamples(for: filteredWorkouts)
    }

    private var periodSummary: ProgressPeriodStats.Summary {
        ProgressPeriodStats.summary(for: filteredWorkouts)
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
        let summary = periodSummary
        return HStack(spacing: 0) {
            summaryStatCell(
                value: "\(summary.runCount)",
                label: "Runs"
            )
            Divider().frame(height: 40)
            summaryStatCell(
                value: summary.totalDistanceMeters.distanceString(unit: appSettings.unitPreference),
                label: "Distance"
            )
            Divider().frame(height: 40)
            summaryStatCell(
                value: summary.latestVDOT.map { String(format: "%.0f", $0) } ?? "--",
                label: "VDOT"
            )
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func summaryStatCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.dsTitle2.monospaced())
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.captionStrong)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(SpokenMetric.spoken(measurement: value))
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        HStack(spacing: 4) {
            ForEach(ChartRange.allCases, id: \.self) { range in
                Button {
                    withAnimation(AppAnimation.bouncy) { selectedRange = range }
                } label: {
                    Text(range.rawValue)
                        .font(.dsSubhead.weight(.semibold).monospaced())
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
                        .font(.dsSubhead.weight(.semibold))
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
                ForEach(weeklyBuckets, id: \.weekStart) { bucket in
                    BarMark(
                        x: .value("Week", bucket.weekStart, unit: .weekOfYear),
                        y: .value(appSettings.unitPreference.distanceLabel, distanceValue(bucket.meters))
                    )
                    .foregroundStyle(Color.brand.gradient)
                    .cornerRadius(4)
                }
                if let selected = selectedVolumeDate, let bucket = closestWeekBucket(to: selected) {
                    selectionRule(x: .value("Week", bucket.weekStart)) {
                        tooltipContainer {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bucket.weekStart, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(String(format: "%.1f %@", distanceValue(bucket.meters), appSettings.unitPreference.distanceLabel))
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
            .chartAccessibility("Weekly volume chart", weeklyVolumeSummary)
        }
    }

    /// Short spoken date label for a chart point, matching what the tooltip shows.
    private func pointLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - Chart accessibility summaries (N18)
    //
    // Each chart's spoken summary is built here rather than inline in the view body:
    // one call per chart keeps the bodies readable and the type-checker's work small.

    private var weeklyVolumeSummary: String {
        ChartAccessibility.summary(
            weeklyBuckets.map {
                ChartAccessibility.Point(label: "week of \(pointLabel($0.weekStart))", value: distanceValue($0.meters))
            }
        ) {
            SpokenMetric.spoken(
                value: String(format: "%.1f", $0),
                unit: appSettings.unitPreference.distanceLabel
            )
        }
    }

    private func paceSummary(_ runs: [RunWorkout]) -> String {
        ChartAccessibility.summary(
            runs.map {
                ChartAccessibility.Point(label: pointLabel($0.date), value: $0.averagePaceSecondsPerKm)
            }
        ) { SpokenMetric.spoken(measurement: $0.paceString(unit: appSettings.unitPreference)) }
    }

    private func heartRateSummary(_ runs: [RunWorkout]) -> String {
        ChartAccessibility.summary(
            runs.map {
                ChartAccessibility.Point(label: pointLabel($0.date), value: $0.averageHeartRate ?? 0)
            }
        ) { "\(Int($0)) beats per minute" }
    }

    private func zoneSummary(_ slices: [HRZoneSlice]) -> String {
        ChartAccessibility.summary(
            slices.map { ChartAccessibility.Point(label: $0.zone.displayTitle, value: $0.seconds) }
        ) { "\(Int(($0 / 60).rounded())) minutes" }
    }

    private func elevationSummary(_ runs: [RunWorkout]) -> String {
        ChartAccessibility.summary(
            runs.map {
                ChartAccessibility.Point(
                    label: pointLabel($0.date),
                    value: ($0.elevationGainMeters ?? 0).elevationValue(unit: appSettings.unitPreference)
                )
            }
        ) {
            SpokenMetric.spoken(value: "\(Int($0))", unit: appSettings.unitPreference.elevationLabel)
        }
    }

    private var vo2Summary: String {
        ChartAccessibility.summary(
            vo2Points.map { ChartAccessibility.Point(label: pointLabel($0.date), value: $0.vdot) }
        ) { String(format: "%.1f", $0) }
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
                .chartAccessibility("Average pace chart", paceSummary(paceWorkouts))
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
                .chartAccessibility("Average heart rate chart", heartRateSummary(withHR))
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
        if didChange { context.saveOrLog("backfilled heart-rate samples") }
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
                    .chartAccessibility("Time in heart-rate zones chart", zoneSummary(slices))
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
                .chartAccessibility("Elevation gain chart", elevationSummary(withElev))
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
                    ForEach(vo2Points, id: \.date) { point in
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
                            selectedVO2Date.flatMap { closestVO2Point(to: $0) } == point ? 80 : 36
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
                .chartAccessibility("Estimated VO₂ max chart", vo2Summary)
                Text("Higher is better fitness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Period summary card

    private var periodSummaryCard: some View {
        let summary = periodSummary

        return chartCard("PERIOD SUMMARY") {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                summaryCell(value: "\(summary.runCount)", label: "Runs")
                summaryCell(
                    value: summary.totalDistanceMeters.distanceString(unit: appSettings.unitPreference),
                    label: "Total Distance"
                )
                summaryCell(
                    value: summary.averagePaceSecondsPerKm.map { $0.paceString(unit: appSettings.unitPreference) } ?? "--",
                    label: "Avg Pace"
                )
                summaryCell(
                    value: summary.averageHeartRate.map { "\(Int($0)) bpm" } ?? "--",
                    label: "Avg Heart Rate"
                )
                summaryCell(
                    value: summary.averageElevationGainMeters.map { $0.elevationString(unit: appSettings.unitPreference) } ?? "--",
                    label: "Avg Elevation"
                )
                summaryCell(
                    value: summary.averageVDOT.map { String(format: "%.1f", $0) } ?? "--",
                    label: "Avg VO₂ Max"
                )
            }
        }
    }

    private func summaryCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.dsCallout.weight(.bold).monospaced())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.surfaceTertiary, in: RoundedRectangle(cornerRadius: 10))
        // One element per cell, and a "--" placeholder is spoken as such rather than as
        // a pair of dashes (N18).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(SpokenMetric.spoken(measurement: value))
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

    private func closestWeekBucket(to date: Date) -> ProgressPeriodStats.WeeklyDistance? {
        weeklyBuckets.min(by: {
            abs($0.weekStart.timeIntervalSince(date)) < abs($1.weekStart.timeIntervalSince(date))
        })
    }

    private func closestVO2Point(to date: Date) -> ProgressPeriodStats.VDOTSample? {
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

    private var weeklyBuckets: [ProgressPeriodStats.WeeklyDistance] {
        ProgressPeriodStats.weeklyDistances(for: filteredWorkouts)
    }

    /// A bucket's distance in the runner's own unit. The bucketing itself stays in
    /// metres so the maths has nothing display-shaped in it (D1).
    private func distanceValue(_ meters: Double) -> Double {
        meters.distanceValue(unit: appSettings.unitPreference)
    }
}
