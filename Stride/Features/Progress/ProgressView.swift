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
        // Imported walks never reach this screen (N38): every chart on it — volume, pace,
        // heart rate, elevation, VO₂ — is a statement about running. `ProgressPeriodStats`
        // enforces the same rule for callers that hand it an unfiltered list; excluding
        // them in the fetch also keeps the heart-rate backfill below from spending its
        // HealthKit queries on walks.
        let walkRaw = WorkoutType.walk.rawValue
        let crossTrainingRaw = WorkoutType.crossTraining.rawValue
        _workouts = Query(
            filter: #Predicate<RunWorkout> {
                $0.date >= cutoff && $0.workoutTypeRaw != walkRaw && $0.workoutTypeRaw != crossTrainingRaw
            },
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
            // Measured VDOT first; the profile's own baseline behind it, labelled as an
            // estimate so the two are never confused. Falling straight through to "--" hid a
            // number the app had already computed and shown during onboarding (S8).
            summaryStatCell(
                value: (summary.latestVDOT ?? profile?.baselineVDOT)
                    .map { String(format: "%.0f", $0) } ?? "--",
                label: summary.latestVDOT == nil && profile?.baselineVDOT != nil
                    ? "VDOT · est."
                    : "VDOT"
            )
        }
        .padding(AppSpacing.lg)
        // The period's totals are what matters most on Progress, so they are its hero,
        // as today's session is on Home and the race is on Plan.
        .heroCard()
    }

    private func summaryStatCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.dsTitle2.monospacedDigit())
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
        StrideSegmentedControl(
            selection: $selectedRange,
            options: ChartRange.allCases,
            monospaced: true
        ) { Text($0.rawValue) }
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        StrideSegmentedControl(
            selection: $selectedTab,
            options: ProgressTab.allCases
        ) { Text($0.rawValue) }
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
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.md)
    }

    // MARK: - Weekly volume chart

    private var weeklyVolumeChart: some View {
        chartCard("WEEKLY VOLUME") {
            // Every other chart on this tab says why it is empty; this one drew an
            // unexplained 160pt of blank card instead.
            if weeklyBuckets.isEmpty {
                emptyDataPlaceholder("No distance data in this period")
            } else {
                Chart {
                    ForEach(weeklyBuckets, id: \.weekStart) { bucket in
                        BarMark(
                            x: .value("Week", bucket.weekStart, unit: .weekOfYear),
                            y: .value(appSettings.unitPreference.distanceLabel, distanceValue(bucket.meters))
                        )
                        .foregroundStyle(.routeBar)
                        .cornerRadius(AppRadius.xs)
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
                .chartAccessibility("Weekly volume chart", weeklyVolumeSeries)
            }
        }
    }

    /// Short spoken date label for a chart point, matching what the tooltip shows.
    private func pointLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - Chart accessibility series (N18 / U10)
    //
    // Each chart's accessible payload is built here rather than inline in the view body:
    // one call per chart keeps the bodies readable and the type-checker's work small.
    //
    // These return a `ChartAccessibility.Series` rather than a finished summary string, so
    // every chart on this tab is both collapsed into one spoken sentence *and* playable as
    // an Audio Graph from the same numbers (U10).

    private var weeklyVolumeSeries: ChartAccessibility.Series {
        let unit = appSettings.unitPreference
        return ChartAccessibility.Series(
            points: weeklyBuckets.map {
                ChartAccessibility.Point(label: "week of \(pointLabel($0.weekStart))", value: distanceValue($0.meters))
            },
            valueAxisLabel: String(localized: "Distance", comment: "Chart value axis")
        ) {
            SpokenMetric.spoken(value: String(format: "%.1f", $0), unit: unit.distanceLabel)
        }
    }

    private func paceSeries(_ runs: [RunWorkout]) -> ChartAccessibility.Series {
        let unit = appSettings.unitPreference
        return ChartAccessibility.Series(
            points: runs.map {
                ChartAccessibility.Point(label: pointLabel($0.date), value: $0.averagePaceSecondsPerKm)
            },
            valueAxisLabel: String(localized: "Pace", comment: "Chart value axis")
        ) { SpokenMetric.spoken(measurement: $0.paceString(unit: unit)) }
    }

    private func heartRateSeries(_ runs: [RunWorkout]) -> ChartAccessibility.Series {
        ChartAccessibility.Series(
            points: runs.map {
                ChartAccessibility.Point(label: pointLabel($0.date), value: $0.averageHeartRate ?? 0)
            },
            valueAxisLabel: String(localized: "Heart rate", comment: "Chart value axis")
        ) { "\(Int($0)) beats per minute" }
    }

    private func zoneSeries(_ slices: [HRZoneSlice]) -> ChartAccessibility.Series {
        ChartAccessibility.Series(
            points: slices.map { ChartAccessibility.Point(label: $0.zone.displayTitle, value: $0.seconds) },
            valueAxisLabel: String(localized: "Time", comment: "Chart value axis")
        ) { "\(Int(($0 / 60).rounded())) minutes" }
    }

    private func elevationSeries(_ runs: [RunWorkout]) -> ChartAccessibility.Series {
        let unit = appSettings.unitPreference
        return ChartAccessibility.Series(
            points: runs.map {
                ChartAccessibility.Point(
                    label: pointLabel($0.date),
                    value: ($0.elevationGainMeters ?? 0).elevationValue(unit: unit)
                )
            },
            valueAxisLabel: String(localized: "Elevation gain", comment: "Chart value axis")
        ) {
            SpokenMetric.spoken(value: "\(Int($0))", unit: unit.elevationLabel)
        }
    }

    private var vo2Series: ChartAccessibility.Series {
        ChartAccessibility.Series(
            points: vo2Points.map { ChartAccessibility.Point(label: pointLabel($0.date), value: $0.vdot) },
            valueAxisLabel: String(localized: "VO₂ max", comment: "Chart value axis")
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
                        .foregroundStyle(.route)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
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
                // Pace never approaches zero, so the default zero-anchored domain pushed
                // every point into the top quarter of the plot and flattened the trend
                // the card exists to show. Bracket the data instead.
                .chartYScale(domain: paceDomain(paceWorkouts))
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            // `paceValueString` is the bare "M:SS" form — the axis has no
                            // room for a unit, and the card's own footnote carries it.
                            // Guarded because a tick at or below zero formats as the
                            // "--:--" placeholder, which rendered as a literal axis label.
                            if let secs = value.as(Double.self), secs > 0 {
                                Text(secs.paceValueString(unit: appSettings.unitPreference))
                            }
                        }
                    }
                }
                .chartXSelection(value: $selectedPaceDate)
                .chartAccessibility("Average pace chart", paceSeries(paceWorkouts))
                Text("Lower is faster")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A y-domain that brackets the paces actually run, with a little air above and
    /// below so the fastest and slowest points are not drawn on the frame.
    ///
    /// Padding is a share of the spread rather than a fixed number of seconds, so a
    /// tight month and a varied year both fill the plot. A single run — or a set that
    /// happens to share one pace — has no spread to scale, so it falls back to a
    /// half-minute either side rather than collapsing to a zero-height domain.
    private func paceDomain(_ workouts: [RunWorkout]) -> ClosedRange<Double> {
        let paces = workouts.map(\.averagePaceSecondsPerKm)
        guard let fastest = paces.min(), let slowest = paces.max() else { return 0...1 }
        let padding = max((slowest - fastest) * 0.15, 30)
        return max(0, fastest - padding)...(slowest + padding)
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
                .chartAccessibility("Average heart rate chart", heartRateSeries(withHR))
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
                    .padding(.vertical, AppSpacing.xxl)
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
                        .cornerRadius(AppRadius.xs)
                    }
                    .chartYScale(domain: HRZone.allCases.reversed().map(\.shortName))
                    .chartXAxisLabel("minutes")
                    .frame(height: 150)
                    .chartAccessibility("Time in heart-rate zones chart", zoneSeries(slices))
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
                        .cornerRadius(AppRadius.xs)
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
                .chartAccessibility("Elevation gain chart", elevationSeries(withElev))
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
                // Same reason as the pace chart: VDOT sits in the 30s–50s for most
                // runners, so a zero-anchored domain spends half the plot on numbers
                // nobody will record and flattens the trend the card exists to show.
                .chartYScale(domain: vo2Domain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartXSelection(value: $selectedVO2Date)
                .chartAccessibility("Estimated VO₂ max chart", vo2Series)
                Text("Higher is better fitness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Brackets the recorded VDOT values, padded like ``paceDomain(_:)`` and clamped so
    /// the axis never runs below zero on a very low estimate.
    private var vo2Domain: ClosedRange<Double> {
        let values = vo2Points.map(\.vdot)
        guard let lowest = values.min(), let highest = values.max() else { return 0...1 }
        let padding = max((highest - lowest) * 0.15, 2)
        return max(0, lowest - padding)...(highest + padding)
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
        .padding(AppSpacing.md)
        .background(Color.surfaceTertiary, in: RoundedRectangle(cornerRadius: AppRadius.sm))
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
        // The selected point is "you are here" on the chart, so the rule is the brand's.
        RuleMark(x: x)
            .foregroundStyle(Color.brand.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
            .annotation(
                position: .top,
                overflowResolution: .init(x: .fit(to: .chart), y: .disabled),
                content: label
            )
    }

    private func tooltipContainer<C: View>(@ViewBuilder content: () -> C) -> some View {
        content()
            .padding(.horizontal, AppSpacing.sm).padding(.vertical, 5)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous).strokeBorder(.cardStroke, lineWidth: 1))
            .appShadow(.e2)
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
