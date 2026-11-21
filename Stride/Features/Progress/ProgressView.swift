import SwiftUI
import Charts
import SwiftData

struct ProgressDashboardView: View {
    /// Every run, oldest first: the filter reaches back to the first run ("All"), so the
    /// one-year bound this fetch used to have (U9) no longer fits.
    @Query private var workouts: [RunWorkout]

    @Query private var profiles: [UserProfile]
    private var profile: UserProfile? { profiles.first }

    /// Strength sessions over the same window as the runs, for the strength card.
    @Query private var strengthSessions: [StrengthWorkout]

    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var context
    /// The one filter every card follows, pinned at the top of the page.
    @State private var period: ProgressFilter.Period = .threeMonths
    @State private var runType: ProgressFilter.RunType = .all
    /// The week, month or day the runner drilled into by tapping a bar. `nil` is the
    /// whole period.
    @State private var drill: DateInterval?
    /// What the main chart measures. The hero's totals pick it.
    @State private var measure: VolumeExplorer.Metric = .distance
    /// Whether the run list shows every run rather than the latest few.
    @State private var showsAllRuns = false

    /// HealthKit ids already asked for HR samples this session, so a run whose source
    /// workout is gone isn't re-queried on every period change (N25).
    @State private var attemptedBackfillIDs: Set<String> = []
    @State private var isBackfillingHeartRate = false

    @State private var selectedPaceDate: Date? = nil
    @State private var selectedHRDate: Date? = nil
    @State private var selectedElevationDate: Date? = nil
    @State private var selectedVO2Date: Date? = nil

    @State private var progressAppeared = false
    @State private var selectedTab: ProgressTab = .stats

    /// Two tabs: trends over time, and what they add up to. Race insights moved to Plan,
    /// beside the race they predict.
    enum ProgressTab: String, CaseIterable {
        case stats    = "Stats"
        case medals   = "Achievements"
    }

    init() {
        // Imported walks never reach this screen (N38): every chart on it — volume, pace,
        // heart rate, elevation, VO₂ — is a statement about running. `ProgressPeriodStats`
        // enforces the same rule for callers that hand it an unfiltered list; excluding
        // them in the fetch also keeps the heart-rate backfill below from spending its
        // HealthKit queries on walks.
        let walkRaw = WorkoutType.walk.rawValue
        let crossTrainingRaw = WorkoutType.crossTraining.rawValue
        _workouts = Query(
            filter: #Predicate<RunWorkout> {
                $0.workoutTypeRaw != walkRaw && $0.workoutTypeRaw != crossTrainingRaw
            },
            sort: [SortDescriptor(\RunWorkout.date)]
        )
        _strengthSessions = Query(sort: [SortDescriptor(\StrengthWorkout.date)])
    }

    // The period arithmetic — which runs are in range, what they total, how they bucket
    // by week, and the VDOT series — lives in `ProgressPeriodStats` rather than in these
    // body-evaluated properties (D1). What's left here is the range the runner picked
    // and the unit they read it in.

    /// The runs of the picked type, the whole history.
    private var typedWorkouts: [RunWorkout] {
        workouts.filter { $0.countsAsRunning && runType.includes($0.workoutType.progressRunKind) }
    }

    /// The runs of the picked type in the picked period: what every chart below reads.
    private var filteredWorkouts: [RunWorkout] {
        guard let days = period.days else { return typedWorkouts }
        return ProgressPeriodStats.runs(in: typedWorkouts, withinDays: days)
    }

    private var vo2Points: [ProgressPeriodStats.VDOTSample] {
        ProgressPeriodStats.vdotSamples(for: filteredWorkouts)
    }

    /// The filtered runs narrowed to the drilled-in week, month or day, if any: what the
    /// zones, best efforts, summary and run list read. The trend charts keep the whole
    /// period and shade the drilled-in stretch instead, so the week reads in context.
    private var scopedWorkouts: [RunWorkout] {
        guard drill != nil else { return filteredWorkouts }
        return filteredWorkouts.filter { ProgressFilter.contains(drill, $0.date) }
    }

    private var periodSummary: ProgressPeriodStats.Summary {
        ProgressPeriodStats.summary(for: scopedWorkouts)
    }

    var body: some View {
        let dashboard = makeDashboard()
        NavigationStack {
            VStack(spacing: 0) {
                tabPicker
                if selectedTab == .stats {
                    // The filter sits right under the tabs, above everything it changes,
                    // and stays there while the page scrolls under it.
                    filterBar(dashboard)
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.bottom, AppSpacing.xs)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // One `stagger` step per card, in reading order, capped at six.
                            heroTotals(dashboard)
                                .strideEntrance(progressAppeared)
                            // The chart and the runs it drills into sit together, so a
                            // tapped bar's runs are right under it.
                            StrideColumns(spacing: 16) {
                                volumeChart(dashboard)
                                    .strideEntrance(progressAppeared, delay: AppAnimation.stagger)
                            } trailing: {
                                runList
                                    .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 2)
                            }
                            // Pairs, so on a wide page (iPhone Duo open, in landscape) the charts
                            // read as a grid with the gap on the fold.
                            StrideColumns(spacing: 16) {
                                paceProgressChart
                                    .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 3)
                            } trailing: {
                                heartRateTrendChart
                                    .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 4)
                            }
                            StrideColumns(spacing: 16) {
                                heartRateZoneChart
                                    .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 5)
                            } trailing: {
                                elevationTrendChart
                                    .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 6)
                            }
                            vo2MaxTrendChart
                                .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 6)
                            // These three have their own all-time queries (a record is measured
                            // against every run ever), and take the filter as parameters.
                            BestEffortsCard(scope: scopedIDs)
                                .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 6)
                            FitnessFreshnessCard(periodDays: period.days, asOf: fitnessAsOf)
                                .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 6)
                            ActivityCalendarCard(
                                runType: runType,
                                weeks: runningDaysWeeks,
                                selectedDay: drill,
                                onPick: pickDay
                            )
                            .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 6)
                            if showsStrengthCard {
                                strengthCard
                                    .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 6)
                            }
                            periodSummaryCard
                                .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 6)
                            RouteHeatmapCard(periodDays: period.days, runType: runType)
                                .strideEntrance(progressAppeared, delay: AppAnimation.stagger * 6)
                        }
                        .padding()
                        .strideReadableWidth(hasColumns: true)
                        // A tap on the page outside any control undoes the drill-in. Buttons,
                        // links and the charts' own gestures sit inside and win over this one.
                        .contentShape(Rectangle())
                        .onTapGesture { clearDrill() }
                        .task { progressAppeared = true }
                        .task(id: period) { await backfillHeartRateSamples() }
                    }
                } else {
                    AchievementsView()
                }
            }
            .background(Color.surfacePrimary)
            .navigationTitle("Progress")
        }
        .onChange(of: period) { filterChanged() }
        .onChange(of: runType) { filterChanged() }
        .onChange(of: selectedTab) {
            if selectedTab == .stats {
                progressAppeared = false
                Task { @MainActor in progressAppeared = true }
            }
        }
    }

    /// Undoes everything that belonged to the old filter: a drilled-in bar no longer
    /// exists, and a chart's picked point may no longer be drawn.
    private func filterChanged() {
        drill = nil
        showsAllRuns = false
        selectedPaceDate = nil
        selectedHRDate = nil
        selectedElevationDate = nil
        selectedVO2Date = nil
    }

    // MARK: - Dashboard: the filter, the totals and the main chart

    /// Everything the hero and the main chart draw, worked out once per body pass.
    struct DashboardSnapshot {
        let buckets: [VolumeExplorer.Bucket]
        let summaries: [VolumeExplorer.Metric: VolumeExplorer.Summary]
    }

    private func makeDashboard(now: Date = .now) -> DashboardSnapshot {
        let calendar = VolumeExplorer.calendar()
        let runs = typedWorkouts.map {
            VolumeExplorer.Run(
                id: $0.id,
                date: $0.date,
                meters: $0.distanceMeters,
                seconds: $0.durationSeconds,
                climbMeters: $0.elevationGainMeters
            )
        }
        let start = VolumeExplorer.windowStart(
            period.window, now: now, earliestRun: runs.first?.date, calendar: calendar
        )
        let buckets = VolumeExplorer.buckets(
            for: runs, grouping: period.grouping, from: start, through: now, calendar: calendar
        )
        var summaries: [VolumeExplorer.Metric: VolumeExplorer.Summary] = [:]
        for metric in VolumeExplorer.Metric.allCases {
            summaries[metric] = VolumeExplorer.summary(
                metric: metric, runs: runs, buckets: buckets, window: period.window, from: start, now: now
            )
        }
        return DashboardSnapshot(buckets: buckets, summaries: summaries)
    }

    /// Period and run type as chips, and the drill-in as a chip that undoes it. Chips
    /// rather than a second segmented control: the tabs above already draw the route
    /// under their choice, and the route means progress or go.
    private func filterBar(_ dashboard: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(ProgressFilter.Period.allCases, id: \.self) { option in
                    Button {
                        withAnimation(AppAnimation.bouncy) { period = option }
                    } label: {
                        Text(option.rawValue).monospacedDigit()
                    }
                    .buttonStyle(.strideChip(selected: period == option))
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(period == option ? [.isButton, .isSelected] : .isButton)
                }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    ForEach(ProgressFilter.RunType.allCases, id: \.self) { option in
                        Button {
                            withAnimation(AppAnimation.bouncy) { runType = option }
                        } label: {
                            Text(option.title)
                        }
                        .buttonStyle(.strideChip(selected: runType == option))
                        .accessibilityAddTraits(runType == option ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, AppSpacing.xxs)
            }
            if let drill {
                HStack(spacing: AppSpacing.sm) {
                    Button {
                        withAnimation(AppAnimation.quick) {
                            self.drill = nil
                            showsAllRuns = false
                        }
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            Text(drillTitle(drill))
                            StrideIcon(name: .close, size: 11, color: .brandText, strokeWeight: 2.4)
                        }
                    }
                    .buttonStyle(.strideChip(selected: false))
                    .accessibilityLabel(drillTitle(drill))
                    .accessibilityHint("Shows the whole period again")
                    Text("Everything below is from this \(drill.duration <= 26 * 3_600 ? String(localized: "day") : period.grouping.noun)")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
    }

    /// "Week of Nov 16", "October 2026".
    private func drillTitle(_ drill: DateInterval) -> String {
        // A day from the running-days grid.
        if drill.duration <= 26 * 3_600 {
            return drill.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        switch period.grouping {
        case .week:
            return String(localized: "Week of \(drill.start.formatted(.dateTime.month(.abbreviated).day()))")
        case .month:
            return drill.start.formatted(.dateTime.month(.wide).year())
        }
    }

    /// The period's totals are what matters most on Progress, so they are its hero, as
    /// today's session is on Home and the race is on Plan. Each total picks what the
    /// chart below measures, which is the job the volume explorer used to do.
    private func heroTotals(_ dashboard: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("\(period.title) · \(runType.title)")
                .strideEyebrow()
                .foregroundStyle(Color.brandText)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: AppSpacing.sm), GridItem(.flexible())],
                alignment: .leading,
                spacing: AppSpacing.xs
            ) {
                ForEach(VolumeExplorer.Metric.allCases, id: \.self) { metric in
                    totalTile(metric, summary: dashboard.summaries[metric])
                }
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroCard()
    }

    private func totalTile(_ metric: VolumeExplorer.Metric, summary: VolumeExplorer.Summary?) -> some View {
        let units = VolumeUnits(metric: metric, unit: appSettings.unitPreference)
        let isOn = measure == metric
        let change = changeText(summary)
        return Button {
            withAnimation(AppAnimation.bouncy) { measure = metric }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(units.figure(summary?.total ?? 0))
                    .font(.dsTitle2.monospacedDigit())
                    .foregroundStyle(.primary)
                    // Rolls to the new total when the filter changes.
                    .strideNumericTransition()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(metric.title)
                    .font(.captionStrong)
                    .foregroundStyle(isOn ? Color.brandText : .secondary)
                Text(change)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // The route under the total the chart shows: this is the one that's "on".
                Capsule()
                    .fill(.route)
                    .frame(width: 28, height: 3)
                    .opacity(isOn ? 1 : 0)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.title)
        .accessibilityValue("\(SpokenMetric.spoken(measurement: units.text(summary?.total ?? 0))). \(change)")
        .accessibilityHint("Charts \(metric.title.lowercased()) below")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// Neutral on purpose: more running is not always better, and a down period is often
    /// the taper or the recovery the plan asked for.
    private func changeText(_ summary: VolumeExplorer.Summary?) -> String {
        guard period != .all else { return String(localized: "Since your first run") }
        guard let summary, let change = summary.change else {
            return String(localized: "Nothing the \(period.window.spokenLength) before")
        }
        let percent = Int((change * 100).rounded())
        if percent == 0 { return String(localized: "Same as the \(period.window.spokenLength) before") }
        return percent > 0
            ? String(localized: "Up \(percent)% on the \(period.window.spokenLength) before")
            : String(localized: "Down \(abs(percent))% on the \(period.window.spokenLength) before")
    }

    /// The measure the hero picked, by week or month, every empty period drawn as the gap
    /// it was. A tap on a bar drills the page into it.
    private func volumeChart(_ dashboard: DashboardSnapshot) -> some View {
        let units = VolumeUnits(metric: measure, unit: appSettings.unitPreference)
        let noun = period.grouping.noun
        let summary = dashboard.summaries[measure]
        let average = units.plotted(summary?.averagePerBucket ?? 0)
        let isEmpty = dashboard.buckets.allSatisfy { $0.value(measure) == 0 }
        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(measure.title) by \(noun)")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppSpacing.sm)
                if !isEmpty {
                    Text(drill == nil ? LocalizedStringKey("Tap a bar to drill in") : "Tap again to see all")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, AppSpacing.xs)
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if isEmpty {
                    emptyDataPlaceholder("No runs in this filter")
                } else {
                    Chart {
                        ForEach(dashboard.buckets) { bucket in
                            BarMark(
                                x: .value("Period", bucket.start, unit: period.grouping.component),
                                y: .value(measure.title, units.plotted(bucket.value(measure)))
                            )
                            .foregroundStyle(.routeBar)
                            .cornerRadius(AppRadius.micro)
                            // Only a drilled-in page fades the other bars.
                            .opacity(drill.map { $0.start >= bucket.start && $0.start < bucket.end } ?? true ? 1 : 0.35)
                        }
                        if average > 0 {
                            RuleMark(y: .value("Average", average))
                                .foregroundStyle(Color.secondary.opacity(0.6))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                    }
                    .frame(height: 180)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month, count: monthLabelStride(dashboard.buckets))) {
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(units.axis(number))
                                }
                            }
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    tapVolumeChart(at: location, proxy: proxy, geometry: geometry, buckets: dashboard.buckets)
                                }
                        }
                    }
                    .chartAccessibility("\(measure.title) by \(noun)", volumeSeries(dashboard.buckets, units: units))
                    if let best = summary?.best {
                        Text("Biggest \(noun): \(bucketTitle(best)), \(units.text(best.value(measure))). Dashed line: \(units.text(summary?.averagePerBucket ?? 0)) a \(noun) on average.")
                            .font(.dsFootnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strideCard()
        }
    }

    /// One label a month up to a year and a half; past that, every few.
    private func monthLabelStride(_ buckets: [VolumeExplorer.Bucket]) -> Int {
        guard let first = buckets.first?.start, let last = buckets.last?.end else { return 1 }
        let months = VolumeExplorer.calendar().dateComponents([.month], from: first, to: last).month ?? 0
        switch months {
        case ..<19: return 1
        case ..<37: return 3
        default: return 6
        }
    }

    private func bucketTitle(_ bucket: VolumeExplorer.Bucket) -> String {
        drillTitle(ProgressFilter.drill(for: bucket))
    }

    private func volumeSeries(_ buckets: [VolumeExplorer.Bucket], units: VolumeUnits) -> ChartAccessibility.Series {
        ChartAccessibility.Series(
            points: buckets.map {
                ChartAccessibility.Point(label: bucketTitle($0), value: units.plotted($0.value(measure)))
            },
            valueAxisLabel: measure.title
        ) { SpokenMetric.spoken(measurement: units.axis($0)) }
    }

    // MARK: - Runs

    /// The runs behind the page: the drilled-in bar's, or the period's latest. Every
    /// drill-in ends here, one tap from the run.
    private var runList: some View {
        let unit = appSettings.unitPreference
        let inScope = scopedWorkouts.reversed()
        let all = Array(inScope)
        // A drilled-in week shows every run; the whole period shows the latest few.
        let limit = drill == nil && !showsAllRuns ? 3 : all.count
        let shown = Array(all.prefix(limit))
        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(drill.map { drillTitle($0) } ?? String(localized: "Latest runs"))
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppSpacing.sm)
                Text(all.count == 1 ? String(localized: "1 run") : String(localized: "\(all.count) runs"))
                    .font(.captionStrong)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.xs)
            VStack(spacing: 0) {
                if shown.isEmpty {
                    Text(drill == nil ? "No runs in this filter." : "No runs. Time off.")
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                        .padding(AppSpacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, workout in
                    NavigationLink {
                        RunSummaryView(workout: workout)
                    } label: {
                        ProgressRunRow(workout: workout, unit: unit)
                    }
                    .buttonStyle(.plain)
                    if index < shown.count - 1 {
                        Divider().padding(.leading, AppSpacing.lg)
                    }
                }
                if all.count > shown.count || (showsAllRuns && drill == nil && all.count > 3) {
                    Divider()
                    Button {
                        withAnimation(AppAnimation.quick) { showsAllRuns.toggle() }
                    } label: {
                        Text(showsAllRuns ? "Show fewer" : "Show all \(all.count) runs")
                            .font(.bodyStrong)
                            .foregroundStyle(Color.brandText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.md)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .strideCard()
        }
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

    private func chartCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // The title sits above the card, as section headers do on every other screen.
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title)
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            content()
                .padding(AppSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .strideCard()
        }
    }

    /// The drilled-in week, month or day, shaded on a chart that keeps the whole period,
    /// so the stretch reads in context. Nothing when the page isn't drilled in.
    @ChartContentBuilder
    private var drillBand: some ChartContent {
        if let drill {
            RectangleMark(
                xStart: .value("From", drill.start),
                xEnd: .value("To", drill.end)
            )
            .foregroundStyle(Color.brand.opacity(0.1))
        }
    }

    private var scopedIDs: Set<UUID> { Set(scopedWorkouts.map(\.id)) }

    /// The last moment of the drill-in, so fitness reads as of that day; `nil` is today.
    private var fitnessAsOf: Date? { drill.map { $0.end.addingTimeInterval(-1) } }

    /// A tap on the main chart drills into the bar under the finger. A tap on the bar
    /// already drilled into, or beside the bars, undoes it.
    private func tapVolumeChart(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        buckets: [VolumeExplorer.Bucket]
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let plot = geometry[plotFrame]
        let x = location.x - plot.minX
        guard x >= 0, x <= plot.width,
              let date: Date = proxy.value(atX: x),
              let bucket = ProgressFilter.bucket(at: date, in: buckets)
        else {
            clearDrill()
            return
        }
        let picked = ProgressFilter.drill(for: bucket)
        withAnimation(AppAnimation.quick) {
            drill = drill == picked ? nil : picked
            showsAllRuns = false
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Back to the whole period.
    private func clearDrill() {
        guard drill != nil else { return }
        withAnimation(AppAnimation.quick) {
            drill = nil
            showsAllRuns = false
        }
    }

    /// A tap on a running day drills into it; a second tap on the same day undoes it.
    private func pickDay(_ day: DateInterval) {
        withAnimation(AppAnimation.quick) {
            drill = drill == day ? nil : day
            showsAllRuns = false
        }
    }

    /// Weeks of running days to draw: the period's, capped at half a year so a square
    /// stays big enough to tap.
    private var runningDaysWeeks: Int {
        guard let days = period.days else { return 26 }
        return min(26, days / 7 + 1)
    }

    // MARK: - Strength

    private var strengthStats: StrengthPeriodStats {
        StrengthPeriodStats.make(
            from: strengthSessions
                .filter { ProgressFilter.contains(drill, $0.date) }
                .map { $0.sessionLog(unit: appSettings.unitPreference) },
            withinDays: period.days ?? 36_500
        )
    }

    /// For a runner who does strength at all: sessions in the window, or equipment chosen
    /// so the plan schedules them. A runner who never lifts doesn't get an empty card.
    private var showsStrengthCard: Bool {
        !strengthSessions.isEmpty || !(profile?.selectedEquipment.isEmpty ?? true)
    }

    private var strengthCard: some View {
        let stats = strengthStats
        let unit = appSettings.unitPreference
        return chartCard("STRENGTH") {
            if stats.sessions == 0 {
                emptyDataPlaceholder("No strength sessions in this period")
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                        Text(verbatim: "\(stats.sessions)")
                            .font(.dsTitle3.weight(.bold))
                            .monospacedDigit()
                        Text(stats.sessions == 1 ? LocalizedStringKey("session") : "sessions")
                            .font(.dsFootnote).foregroundStyle(.secondary)
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Text("\(stats.sessionsPerWeek, format: .number.precision(.fractionLength(1))) a week")
                            .font(.dsFootnote).foregroundStyle(.secondary)
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Text("\(stats.workingSets) sets")
                            .font(.dsFootnote).foregroundStyle(.secondary)
                    }

                    if stats.lifts.isEmpty {
                        Text("Log a weight on your sets to see your lifts here.")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(stats.lifts, id: \.exerciseName) { lift in
                                strengthLiftRow(lift, unit: unit)
                            }
                        }
                        Text("Change is in estimated one-rep max, first session in this period to the latest.")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func strengthLiftRow(_ lift: StrengthPeriodStats.LiftTrend, unit: UnitPreference) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: lift.exerciseName)
                    .font(.dsSubhead.weight(.semibold))
                Text("\(StrengthProgression.weightText(lift.latestWeightKilograms, unit: unit)) × \(lift.latestReps)")
                    .font(.dsCaption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppSpacing.sm)
            if let change = lift.change {
                let percent = Int((change * 100).rounded())
                if percent > 0 {
                    Text("+\(percent)%")
                        .font(.dsSubhead.weight(.bold)).monospacedDigit()
                        .foregroundStyle(Color.success)
                } else if percent < 0 {
                    Text("\(percent)%")
                        .font(.dsSubhead.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Holding")
                        .font(.dsFootnote).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
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

    /// Spoken as the weekly line, which is the reading the card leads with; a run-by-run
    /// list of easy paces is the noise the line exists to smooth.
    private func easyPaceSeries(_ trend: ProgressPeriodStats.EasyPaceTrend) -> ChartAccessibility.Series {
        let unit = appSettings.unitPreference
        let points = trend.weeks.count > 1
            ? trend.weeks.map {
                ChartAccessibility.Point(label: "week of \(pointLabel($0.weekStart))", value: $0.paceSecondsPerKm)
            }
            : trend.runs.map { ChartAccessibility.Point(label: pointLabel($0.date), value: $0.paceSecondsPerKm) }
        return ChartAccessibility.Series(
            points: points,
            valueAxisLabel: String(localized: "Easy pace", comment: "Chart value axis")
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
            valueAxisLabel: String(localized: "VDOT", comment: "Chart value axis")
        ) { String(format: "%.0f", $0) }
    }

    // MARK: - Pace trend chart

    private var easyPaceTrend: ProgressPeriodStats.EasyPaceTrend {
        ProgressPeriodStats.easyPaceTrend(for: filteredWorkouts)
    }

    /// Easy and long runs as dots, with each week's typical easy pace as the line.
    ///
    /// This was every run's average pace joined into one smoothed line, which moved with
    /// the week's mix of sessions (a tempo, intervals with their recoveries, a long run)
    /// rather than with fitness, and gave no reading of whether the runner was getting
    /// faster. `ProgressPeriodStats.easyPaceTrend` explains the filter; the card now leads
    /// with that answer and the chart shows the evidence for it.
    private var paceProgressChart: some View {
        let trend = easyPaceTrend
        return chartCard("EASY PACE") {
            if trend.runs.isEmpty {
                emptyDataPlaceholder("No easy or long runs in this period")
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    easyPaceHeadline(trend)
                    easyPaceChart(trend)
                    Text("Easy and long runs only, so the effort is alike. The line is each week's typical pace.")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The card's answer: the latest week's easy pace, and how it moved over the period.
    private func easyPaceHeadline(_ trend: ProgressPeriodStats.EasyPaceTrend) -> some View {
        let unit = appSettings.unitPreference
        return VStack(alignment: .leading, spacing: 2) {
            if let latest = trend.latestWeekPaceSecondsPerKm {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    Text(latest.paceString(unit: unit))
                        .font(.dsTitle3.weight(.bold))
                        .monospacedDigit()
                    Text("latest week")
                        .font(.dsFootnote).foregroundStyle(.secondary)
                }
            }
            if let change = trend.changeSecondsPerKm {
                let seconds = Int(abs(change.paceSecondsValue(unit: unit)).rounded())
                if seconds < Int(SplitPaceStats.onPaceToleranceSeconds) {
                    Text("About the same as earlier in this period")
                        .font(.dsFootnote).foregroundStyle(.secondary)
                } else if change < 0 {
                    Text("\(seconds)s per \(unit.distanceLabel) faster than earlier in this period")
                        .font(.dsFootnote.weight(.semibold)).foregroundStyle(Color.success)
                } else {
                    // Slower easy runs are not a warning: they're often the right call in a
                    // hot spell or a heavy week, so this stays neutral.
                    Text("\(seconds)s per \(unit.distanceLabel) slower than earlier in this period")
                        .font(.dsFootnote).foregroundStyle(.secondary)
                }
            } else {
                Text("Log easy runs across a few weeks to see a trend")
                    .font(.dsFootnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func easyPaceChart(_ trend: ProgressPeriodStats.EasyPaceTrend) -> some View {
        let selectedRun = selectedPaceDate.flatMap { closestEasyRun(to: $0, in: trend.runs) }
        let paceFactor = 1.0.paceSecondsValue(unit: appSettings.unitPreference)
        let paces = trend.runs.map(\.paceSecondsPerKm)
        let paceTicks = PaceAxis.ticks(
            lowerSecondsPerKm: paces.min() ?? 0,
            upperSecondsPerKm: paces.max() ?? 0,
            factor: paceFactor
        )
        return Chart {
            drillBand
            ForEach(trend.runs) { run in
                PointMark(
                    x: .value("Date", run.date),
                    y: .value("sec/km", run.paceSecondsPerKm)
                )
                .foregroundStyle(Color.secondary.opacity(selectedRun?.id == run.id ? 0.9 : 0.35))
                .symbolSize(selectedRun?.id == run.id ? 70 : 30)
            }
            // A line needs two weeks to say anything; one week shows only its dots.
            if trend.weeks.count > 1 {
                ForEach(trend.weeks, id: \.weekStart) { week in
                    LineMark(
                        x: .value("Date", week.plotDate),
                        y: .value("sec/km", week.paceSecondsPerKm),
                        series: .value("Series", "Weekly")
                    )
                    // The runner's progress, so it is the route.
                    .foregroundStyle(.route)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            if let run = selectedRun {
                selectionRule(x: .value("Date", run.date)) {
                    StrideTooltip {
                        VStack(alignment: .leading, spacing: 2) {
                            let day = run.date.formatted(.dateTime.month(.abbreviated).day())
                            Text("\(day) · \(run.workoutType.localizedName)")
                                .font(.dsCaption2).foregroundStyle(.secondary)
                            Text(run.paceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                                .font(.dsCaption).bold()
                        }
                    }
                }
            }
        }
        .frame(height: 140)
        // Pace never approaches zero, so a zero-anchored domain pushed every point into one
        // band and flattened the trend; bracket the data instead. Reversed so a faster pace
        // sits higher and the line climbs as the runner improves.
        .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) {
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            // Whole minutes of the runner's unit (9:00, 10:00), not Charts' round numbers
            // of seconds per km, which read 8:02, 9:23 in miles.
            AxisMarks(values: paceTicks) { value in
                AxisGridLine()
                AxisValueLabel {
                    // The bare "M:SS" form; the headline carries the unit.
                    if let secs = value.as(Double.self), secs > 0 {
                        Text(PaceAxis.label(secondsPerKm: secs, factor: paceFactor))
                    }
                }
            }
        }
        .chartXSelection(value: $selectedPaceDate)
        .chartAccessibility("Easy pace chart", easyPaceSeries(trend))
    }

    private func closestEasyRun(
        to date: Date,
        in runs: [ProgressPeriodStats.EasyPaceTrend.Run]
    ) -> ProgressPeriodStats.EasyPaceTrend.Run? {
        runs.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    // MARK: - Heart rate trend chart

    private var heartRateTrendChart: some View {
        let withHR = filteredWorkouts.filter { $0.averageHeartRate != nil }
        return chartCard("AVERAGE HEART RATE") {
            if withHR.isEmpty {
                emptyDataPlaceholder("No heart rate data in this period")
            } else {
                Chart {
                    drillBand
                    ForEach(withHR) { workout in
                        LineMark(
                            x: .value("Date", workout.date),
                            y: .value("bpm", workout.averageHeartRate ?? 0)
                        )
                        // A trend line, not a zone: zone colours mark training intensity only.
                        .foregroundStyle(Color.brand)
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Date", workout.date),
                            y: .value("bpm", workout.averageHeartRate ?? 0)
                        )
                        .foregroundStyle(Color.brand)
                        .symbolSize(
                            selectedHRDate.flatMap { closestWorkout(to: $0, in: withHR) }?.id == workout.id ? 80 : 36
                        )
                    }
                    if let selected = selectedHRDate,
                       let workout = closestWorkout(to: selected, in: withHR),
                       let hr = workout.averageHeartRate {
                        selectionRule(x: .value("Date", workout.date)) {
                            StrideTooltip {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workout.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.dsCaption2).foregroundStyle(.secondary)
                                    Text("\(Int(hr)) bpm")
                                        .font(.dsCaption).bold()
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
        let perRun = scopedWorkouts.compactMap { run -> [HRZoneSlice]? in
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
                            .font(.dsCaption)
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
                            Text(slice.zone.displayTitle).font(.dsCaption)
                            Spacer()
                            Text(slice.seconds.durationString).font(.dsCaption).monospacedDigit()
                            Text("\(Int((pct * 100).rounded()))%")
                                .font(.dsCaption2).foregroundStyle(.secondary)
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
                    drillBand
                    ForEach(withElev) { workout in
                        BarMark(
                            x: .value("Date", workout.date, unit: .day),
                            y: .value(appSettings.unitPreference.elevationLabel,
                                      (workout.elevationGainMeters ?? 0).elevationValue(unit: appSettings.unitPreference))
                        )
                        // Bars in the route's bar gradient, as every chart's bars: `success`
                        // is a status colour, and `brandGlow` alone is too light on paper.
                        .foregroundStyle(.routeBar)
                        .cornerRadius(AppRadius.xs)
                    }
                    if let selected = selectedElevationDate,
                       let workout = closestWorkout(to: selected, in: withElev),
                       let gain = workout.elevationGainMeters {
                        selectionRule(x: .value("Date", workout.date)) {
                            StrideTooltip {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workout.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.dsCaption2).foregroundStyle(.secondary)
                                    Text(String(format: "+%.0f %@", gain.elevationValue(unit: appSettings.unitPreference), appSettings.unitPreference.elevationLabel))
                                        .font(.dsCaption).bold()
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

    // MARK: - VDOT trend chart

    private var vo2MaxTrendChart: some View {
        // Named VDOT, as the hero above names the same number.
        chartCard("VDOT") {
            if vo2Points.isEmpty {
                emptyDataPlaceholder("Not enough run data in this period")
            } else {
                Chart {
                    drillBand
                    ForEach(vo2Points, id: \.date) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("VDOT", point.vdot)
                        )
                        // Fitness over time is progress, so it is the route.
                        .foregroundStyle(.route)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("VDOT", point.vdot)
                        )
                        .foregroundStyle(Color.brand)
                        .symbolSize(
                            selectedVO2Date.flatMap { closestVO2Point(to: $0) } == point ? 80 : 36
                        )
                    }
                    if let selected = selectedVO2Date,
                       let point = closestVO2Point(to: selected) {
                        selectionRule(x: .value("Date", point.date)) {
                            StrideTooltip {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.dsCaption2).foregroundStyle(.secondary)
                                    Text(String(format: "%.0f VDOT", point.vdot))
                                        .font(.dsCaption).bold()
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
                .chartAccessibility("VDOT chart", vo2Series)
                Text("Higher is better fitness")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Brackets the recorded VDOT values, padded by a share of their spread and clamped so
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
            // Runs and distance are in the hero above; this card carries the averages.
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: AppSpacing.md) {
                summaryCell(
                    value: summary.averagePaceSecondsPerKm.map { $0.paceString(unit: appSettings.unitPreference) } ?? "--",
                    label: "Avg pace"
                )
                summaryCell(
                    value: summary.averageHeartRate.map { "\(Int($0)) bpm" } ?? "--",
                    label: "Avg heart rate"
                )
                summaryCell(
                    value: summary.averageElevationGainMeters.map { $0.elevationString(unit: appSettings.unitPreference) } ?? "--",
                    label: "Avg elevation"
                )
                summaryCell(
                    value: summary.averageVDOT.map { String(format: "%.0f", $0) } ?? "--",
                    label: "Avg VDOT"
                )
            }
        }
    }

    private func summaryCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.dsCallout.weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.dsCaption)
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


}
