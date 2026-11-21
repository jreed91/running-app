import SwiftUI
import SwiftData
import Charts

// MARK: - TrendExplorerView

/// A full page for reading how a run-by-run measure is moving: easy pace, easy-run heart
/// rate, VDOT or cadence, over any window back to the first run. Every run is a dot; the
/// line is the typical value each week; tapping a dot picks that run and opens it.
///
/// The trend explorer: a view with its own query and
/// state, never built from `ProgressView`'s methods (PR #338).
struct TrendExplorerView: View {
    @Environment(AppSettings.self) private var appSettings
    @Query private var workouts: [RunWorkout]

    @State private var metric: TrendExplorer.Metric
    @State private var window: VolumeExplorer.Window
    /// The run the card under the chart describes. `nil` means the latest one.
    @State private var pinnedID: UUID?
    @State private var rawSelection: Date?

    init(metric: TrendExplorer.Metric = .easyPace, window: VolumeExplorer.Window = .threeMonths) {
        _metric = State(initialValue: metric)
        _window = State(initialValue: window)
        let walkRaw = WorkoutType.walk.rawValue
        let crossTrainingRaw = WorkoutType.crossTraining.rawValue
        _workouts = Query(
            filter: #Predicate<RunWorkout> {
                $0.workoutTypeRaw != walkRaw && $0.workoutTypeRaw != crossTrainingRaw
            },
            sort: [SortDescriptor(\RunWorkout.date)]
        )
    }

    // MARK: Data

    private var unit: UnitPreference { appSettings.unitPreference }

    /// Each metric's value for one run, or `nil` when the run doesn't carry it or doesn't
    /// count for it.
    private func value(of run: RunWorkout) -> Double? {
        switch metric {
        case .easyPace:
            guard ProgressPeriodStats.countsAsEasyPace(run.workoutType) else { return nil }
            return run.averagePaceSecondsPerKm
        case .easyHeartRate:
            guard ProgressPeriodStats.countsAsEasyPace(run.workoutType) else { return nil }
            return run.averageHeartRate
        case .vdot:
            return ProgressStatsService.estimatedVDOT(for: run)
        case .cadence:
            return run.averageCadenceStepsPerMinute
        }
    }

    private struct Snapshot {
        let trend: TrendExplorer.Trend
        let selected: TrendExplorer.Point?
    }

    private func makeSnapshot(now: Date = .now) -> Snapshot {
        let calendar = VolumeExplorer.calendar()
        let points = workouts.compactMap { run in
            value(of: run).map { TrendExplorer.Point(id: run.id, date: run.date, value: $0) }
        }
        let start = VolumeExplorer.windowStart(
            window, now: now, earliestRun: workouts.first?.date, calendar: calendar
        )
        let trend = TrendExplorer.trend(for: points, metric: metric, from: start, calendar: calendar)
        let selected = pinnedID.flatMap { id in trend.points.first { $0.id == id } } ?? trend.points.last
        return Snapshot(trend: trend, selected: selected)
    }

    // MARK: Body

    var body: some View {
        let snapshot = makeSnapshot()
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                StrideSegmentedControl(selection: $metric, options: TrendExplorer.Metric.allCases) {
                    Text($0.shortTitle)
                }
                windowPicker
                headline(snapshot.trend)
                chartCard(snapshot)
                if let selected = snapshot.selected,
                   let workout = workouts.first(where: { $0.id == selected.id }) {
                    selectedRunCard(workout, point: selected, best: snapshot.trend.best)
                }
                Text(metric.explanation)
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppSpacing.xs)
            }
            .padding()
            .strideReadableWidth()
        }
        .background(Color.surfacePrimary)
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: window) { pinnedID = nil }
        .onChange(of: metric) { pinnedID = nil }
        .onChange(of: rawSelection) {
            guard let rawSelection,
                  let point = TrendExplorer.point(nearest: rawSelection, in: snapshot.trend.points)
            else { return }
            if pinnedID != point.id {
                pinnedID = point.id
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }

    private var windowPicker: some View {
        HStack(spacing: AppSpacing.sm) {
            ForEach(VolumeExplorer.Window.allCases, id: \.self) { option in
                Button {
                    withAnimation(AppAnimation.bouncy) { window = option }
                } label: {
                    Text(option.rawValue).monospacedDigit()
                }
                .buttonStyle(.strideChip(selected: window == option))
                .accessibilityAddTraits(window == option ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Headline

    private func headline(_ trend: TrendExplorer.Trend) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("\(metric.title) · typical this week".uppercased())
                .strideEyebrow()
                .foregroundStyle(.secondary)
            Text(trend.latestWeek.map { format($0.value) } ?? "--")
                .font(.metricM)
                .foregroundStyle(.primary)
                .strideNumericTransition()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            changeLine(trend)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func changeLine(_ trend: TrendExplorer.Trend) -> some View {
        if let change = trend.change {
            let improving = trend.isImprovement(for: metric, threshold: metric.noiseThreshold)
            Text(changeText(change))
                .font(.dsFootnote.weight(improving == true ? .semibold : .regular))
                // Green only for a real improvement; a slower or higher reading stays
                // neutral, because it is often heat, a hard week or the plan's choice.
                .foregroundStyle(improving == true ? Color.success : Color.secondary)
        } else {
            Text("Log a few weeks of runs to see which way this is moving")
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
        }
    }

    private func changeText(_ change: Double) -> String {
        let span = window == .all ? String(localized: "since you started") : String(localized: "across this period")
        guard abs(change) > metric.noiseThreshold else {
            return String(localized: "About the same \(span)")
        }
        switch metric {
        case .easyPace:
            let seconds = Int(abs(change.paceSecondsValue(unit: unit)).rounded())
            let direction = change < 0 ? String(localized: "faster") : String(localized: "slower")
            return "\(seconds)s per \(unit.distanceLabel) \(direction) \(span)"
        case .easyHeartRate:
            let beats = Int(abs(change).rounded())
            let direction = change < 0 ? String(localized: "lower") : String(localized: "higher")
            return "\(beats) bpm \(direction) \(span)"
        case .vdot:
            let direction = change > 0 ? String(localized: "up") : String(localized: "down")
            return String(format: "%.1f ", abs(change)) + "\(direction) \(span)"
        case .cadence:
            let steps = Int(abs(change).rounded())
            let direction = change > 0 ? String(localized: "higher") : String(localized: "lower")
            return "\(steps) spm \(direction) \(span)"
        }
    }

    // MARK: Chart

    private func chartCard(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Each run, and the typical \(metric.lowercaseTitle) each week".uppercased())
                .strideEyebrow()
                .foregroundStyle(.secondary)
            if snapshot.trend.points.isEmpty {
                HStack(spacing: 10) {
                    StrideIcon(name: .chart, size: 16, color: .secondary, strokeWeight: 1.8)
                    Text(metric.emptyMessage)
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
            } else {
                chart(snapshot)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strideCard()
    }

    private func chart(_ snapshot: Snapshot) -> some View {
        let trend = snapshot.trend
        let selectedID = snapshot.selected?.id
        let bestID = trend.best?.id
        return Chart {
            ForEach(trend.points) { point in
                PointMark(
                    x: .value("Date", point.date),
                    y: .value(metric.title, point.value)
                )
                .foregroundStyle(point.id == bestID ? Color.brand : Color.secondary)
                .opacity(point.id == selectedID ? 1 : 0.4)
                .symbolSize(point.id == selectedID ? 110 : 30)
            }
            // A line needs two weeks to say anything; one week shows only its dots.
            if trend.weeks.count > 1 {
                ForEach(trend.weeks, id: \.weekStart) { week in
                    LineMark(
                        x: .value("Date", week.plotDate),
                        y: .value(metric.title, week.value),
                        series: .value("Series", "Weekly")
                    )
                    .foregroundStyle(.route)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            if let selected = snapshot.selected {
                RuleMark(x: .value("Date", selected.date))
                    .foregroundStyle(Color.brand.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
            }
        }
        .frame(height: 260)
        // Paces sit far from zero, so the domain brackets the data. Pace is reversed so a
        // faster run sits higher and the line climbs as the runner improves.
        .chartYScale(domain: .automatic(includesZero: false, reversed: metric == .easyPace))
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: monthLabelStride(trend))) {
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: axisValues(trend)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self), number > 0 {
                        Text(axisLabel(number))
                    }
                }
            }
        }
        .chartXSelection(value: $rawSelection)
        .chartAccessibility("\(metric.title) by run", accessibilitySeries(trend))
    }

    private func monthLabelStride(_ trend: TrendExplorer.Trend) -> Int {
        guard let first = trend.points.first?.date, let last = trend.points.last?.date else { return 1 }
        let months = VolumeExplorer.calendar().dateComponents([.month], from: first, to: last).month ?? 0
        switch months {
        case ..<19: return 1
        case ..<37: return 3
        default: return 6
        }
    }

    private func accessibilitySeries(_ trend: TrendExplorer.Trend) -> ChartAccessibility.Series {
        // The weekly line is what the chart says; the dots are its evidence.
        let points = trend.weeks.count > 1
            ? trend.weeks.map {
                ChartAccessibility.Point(
                    label: "week of \($0.weekStart.formatted(.dateTime.month(.abbreviated).day()))",
                    value: $0.value
                )
            }
            : trend.points.map {
                ChartAccessibility.Point(label: $0.date.formatted(.dateTime.month(.abbreviated).day()), value: $0.value)
            }
        return ChartAccessibility.Series(points: points, valueAxisLabel: metric.title) {
            SpokenMetric.spoken(measurement: format($0))
        }
    }

    // MARK: Selected run

    private func selectedRunCard(
        _ workout: RunWorkout,
        point: TrendExplorer.Point,
        best: TrendExplorer.Point?
    ) -> some View {
        NavigationLink {
            RunSummaryView(workout: workout)
        } label: {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text(workout.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year()))
                        .strideEyebrow()
                        .foregroundStyle(.secondary)
                    Spacer()
                    if point.id == best?.id {
                        StrideTag("Best in period", tone: .brand)
                    }
                }
                HStack(alignment: .lastTextBaseline, spacing: AppSpacing.lg) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(format(point.value))
                            .font(.metricS)
                            .foregroundStyle(.primary)
                        Text(metric.title)
                            .font(.captionStrong)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.distanceMeters.distanceString(unit: unit))
                            .font(.bodyStrong.monospacedDigit())
                        Text(workout.workoutType.localizedName)
                            .font(.captionStrong)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        Text("Open run")
                        StrideIcon(name: .chevronRight, size: 10, color: .brandText, strokeWeight: 2.2)
                    }
                    .font(.captionStrong)
                    .foregroundStyle(Color.brandText)
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strideCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the run")
    }

    // MARK: Units

    private func format(_ value: Double) -> String {
        switch metric {
        case .easyPace: return value.paceString(unit: unit)
        case .easyHeartRate: return "\(Int(value.rounded())) bpm"
        case .vdot: return String(format: "%.1f", value)
        case .cadence: return "\(Int(value.rounded())) spm"
        }
    }

    /// Tick values for the y axis: pace on whole minutes of the runner's unit, the other
    /// measures on round numbers. An explicit list, because `AxisMarks(values:)` takes
    /// either `.automatic` or a collection, and one function can't return both.
    private func axisValues(_ trend: TrendExplorer.Trend) -> [Double] {
        let values = trend.points.map(\.value)
        let lower = values.min() ?? 0
        let upper = values.max() ?? 0
        guard metric == .easyPace else {
            return PaceAxis.roundTicks(lower: lower, upper: upper)
        }
        return PaceAxis.ticks(
            lowerSecondsPerKm: lower,
            upperSecondsPerKm: upper,
            factor: 1.0.paceSecondsValue(unit: unit)
        )
    }

    private func axisLabel(_ value: Double) -> String {
        switch metric {
        case .easyPace: return PaceAxis.label(secondsPerKm: value, factor: 1.0.paceSecondsValue(unit: unit))
        case .easyHeartRate, .cadence: return "\(Int(value.rounded()))"
        case .vdot: return String(format: "%.0f", value)
        }
    }
}

// MARK: - Labels

extension TrendExplorer.Metric {
    var title: String {
        switch self {
        case .easyPace: return String(localized: "Easy pace")
        case .easyHeartRate: return String(localized: "Easy heart rate")
        case .vdot: return String(localized: "VDOT")
        case .cadence: return String(localized: "Cadence")
        }
    }

    var lowercaseTitle: String {
        self == .vdot ? title : title.lowercased()
    }

    /// For the segmented control, where four long titles don't fit.
    var shortTitle: String {
        switch self {
        case .easyPace: return String(localized: "Pace")
        case .easyHeartRate: return String(localized: "Heart")
        case .vdot: return String(localized: "VDOT")
        case .cadence: return String(localized: "Cadence")
        }
    }

    var emptyMessage: String {
        switch self {
        case .easyPace: return String(localized: "No easy or long runs in this period")
        case .easyHeartRate: return String(localized: "No easy runs with heart rate in this period")
        case .vdot: return String(localized: "No quality sessions or races in this period")
        case .cadence: return String(localized: "No runs with cadence in this period")
        }
    }

    /// What the chart counts, said once under it.
    var explanation: String {
        switch self {
        case .easyPace:
            return String(localized: """
                Easy and long runs only. Holding the effort steady is what makes pace \
                comparable from week to week.
                """)
        case .easyHeartRate:
            return String(localized: """
                Heart rate on easy and long runs. A lower number at the same easy effort \
                is fitness.
                """)
        case .vdot:
            return String(localized: """
                Estimated from quality sessions and races. Easy runs are left out because \
                they are run well below what you can do.
                """)
        case .cadence:
            return String(localized: "Steps per minute on every run that recorded it.")
        }
    }

    /// Changes smaller than this, in the metric's own units, read as "about the same".
    var noiseThreshold: Double {
        switch self {
        case .easyPace: return 3 // seconds per km
        case .easyHeartRate: return 1.5
        case .vdot: return 0.3
        case .cadence: return 1.5
        }
    }
}
