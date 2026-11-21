import SwiftUI
import SwiftData
import Charts

// MARK: - VolumeExplorerView

/// A full page for reading training volume: distance, time, runs or climb, by week or by
/// month, over any window back to the first run, with the runs behind each bar one tap
/// away.
///
/// Progress shows a small weekly bar chart for the picked range. This is where it opens
/// to when the runner wants more than a glance: the bars are big enough to tap, every
/// empty week is drawn as the gap it was, the headline compares the window with the one
/// before it, and the list under the chart opens any run in the selected bar.
///
/// Its own view with its own query and state, never built from `ProgressView`'s methods:
/// a pushed page that writes its parent's state rebuilds itself in a loop (PR #338).
struct VolumeExplorerView: View {
    @Environment(AppSettings.self) private var appSettings
    @Query private var workouts: [RunWorkout]

    @State private var metric: VolumeExplorer.Metric
    @State private var window: VolumeExplorer.Window
    @State private var grouping: VolumeExplorer.Grouping
    /// The bar whose runs are listed. `nil` means the latest one.
    @State private var pinnedStart: Date?
    /// Where the finger is on the chart, while it is there.
    @State private var rawSelection: Date?

    init(metric: VolumeExplorer.Metric = .distance, window: VolumeExplorer.Window = .threeMonths) {
        _metric = State(initialValue: metric)
        _window = State(initialValue: window)
        _grouping = State(initialValue: window.defaultGrouping)
        // All time, so the window can reach back to the first run. Walks and imported
        // cross-training stay out, as they do on Progress (N38).
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

    private var calendar: Calendar { VolumeExplorer.calendar() }
    private var unit: UnitPreference { appSettings.unitPreference }

    private var runs: [VolumeExplorer.Run] {
        workouts.map {
            VolumeExplorer.Run(
                id: $0.id,
                date: $0.date,
                meters: $0.distanceMeters,
                seconds: $0.durationSeconds,
                climbMeters: $0.elevationGainMeters
            )
        }
    }

    /// Everything the page draws, worked out once per body pass.
    private struct Snapshot {
        let buckets: [VolumeExplorer.Bucket]
        let summary: VolumeExplorer.Summary
        let selected: VolumeExplorer.Bucket?
    }

    private func makeSnapshot(now: Date = .now) -> Snapshot {
        let runs = self.runs
        let start = VolumeExplorer.windowStart(
            window, now: now, earliestRun: runs.first?.date, calendar: calendar
        )
        let buckets = VolumeExplorer.buckets(
            for: runs, grouping: grouping, from: start, through: now, calendar: calendar
        )
        let summary = VolumeExplorer.summary(
            metric: metric, runs: runs, buckets: buckets, window: window, now: now
        )
        let selected = pinnedStart.flatMap { start in buckets.first { $0.start == start } }
            ?? buckets.last
        return Snapshot(buckets: buckets, summary: summary, selected: selected)
    }

    // MARK: Body

    var body: some View {
        let snapshot = makeSnapshot()
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                metricPicker
                windowPicker
                headline(snapshot.summary)
                chartCard(snapshot)
                if let selected = snapshot.selected {
                    runList(for: selected)
                }
            }
            .padding()
            .strideReadableWidth()
        }
        .background(Color.surfacePrimary)
        .navigationTitle("Volume")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: window) {
            grouping = window.defaultGrouping
            pinnedStart = nil
        }
        .onChange(of: grouping) { pinnedStart = nil }
        .onChange(of: rawSelection) {
            // A tap or a drag picks the bar under the finger, and it stays picked when
            // the finger lifts, so the list below keeps showing that bar's runs.
            guard let rawSelection,
                  let bucket = VolumeExplorer.bucket(nearest: rawSelection, in: snapshot.buckets)
            else { return }
            if pinnedStart != bucket.start {
                pinnedStart = bucket.start
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }

    // MARK: Controls

    private var metricPicker: some View {
        StrideSegmentedControl(selection: $metric, options: VolumeExplorer.Metric.allCases) {
            Text($0.title)
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

    /// Two choices, so one chip that flips between them rather than a menu.
    private var groupingToggle: some View {
        Button {
            withAnimation(AppAnimation.bouncy) {
                grouping = grouping == .week ? .month : .week
            }
        } label: {
            Text(grouping.title)
        }
        .buttonStyle(.strideChip(selected: false))
        .accessibilityLabel("Group by")
        .accessibilityValue(grouping.title)
        .accessibilityHint("Switches between weekly and monthly bars")
    }

    // MARK: Headline

    private func headline(_ summary: VolumeExplorer.Summary) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(window == .all ? "All time" : "Last \(window.spokenLength)")
                .strideEyebrow()
                .foregroundStyle(.secondary)
            Text(format(summary.total))
                .font(.metricM)
                .foregroundStyle(.primary)
                .strideNumericTransition()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                if let change = summary.change {
                    changeTag(change)
                }
                Text("\(format(summary.averagePerBucket)) a \(grouping.noun) on average")
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroCard()
        .accessibilityElement(children: .combine)
    }

    private func changeTag(_ change: Double) -> some View {
        let percent = Int((change * 100).rounded())
        let text = percent == 0
            ? "Same as the \(window.spokenLength) before"
            : "\(percent > 0 ? "Up" : "Down") \(abs(percent))% on the \(window.spokenLength) before"
        return Text(text)
            .font(.captionStrong)
            // Neutral on purpose: more running is not always better, and a down week
            // is often the taper or the recovery the plan asked for.
            .foregroundStyle(.primary)
    }

    // MARK: Chart

    private func chartCard(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(metric.title) by \(grouping.noun)".uppercased())
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppSpacing.sm)
                groupingToggle
            }
            if snapshot.buckets.allSatisfy({ $0.value(metric) == 0 }) {
                HStack(spacing: 10) {
                    StrideIcon(name: .chart, size: 16, color: .secondary, strokeWeight: 1.8)
                    Text("No runs in this period")
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
            } else {
                chart(snapshot)
            }
            if let best = snapshot.summary.best {
                Text("Biggest \(grouping.noun): \(periodLabel(best)), \(format(best.value(metric)))")
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strideCard()
    }

    private func chart(_ snapshot: Snapshot) -> some View {
        let selectedStart = snapshot.selected?.start
        let average = displayValue(snapshot.summary.averagePerBucket)
        return Chart {
            ForEach(snapshot.buckets) { bucket in
                BarMark(
                    x: .value("Period", bucket.start, unit: grouping.component),
                    y: .value(metric.title, displayValue(bucket.value(metric)))
                )
                .foregroundStyle(.routeBar)
                .cornerRadius(AppRadius.micro)
                .opacity(selectedStart == nil || bucket.start == selectedStart ? 1 : 0.35)
            }
            if average > 0 {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("avg")
                            .font(.dsCaption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(height: 240)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: monthLabelStride(spanMonths(snapshot.buckets)))) {
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(axisLabel(number))
                    }
                }
            }
        }
        .chartXSelection(value: $rawSelection)
        .chartAccessibility("\(metric.title) by \(grouping.noun)", accessibilitySeries(snapshot.buckets))
    }

    /// How many months the bars cover, whichever way they are grouped.
    private func spanMonths(_ buckets: [VolumeExplorer.Bucket]) -> Int {
        guard let first = buckets.first?.start, let last = buckets.last?.end else { return 0 }
        return calendar.dateComponents([.month], from: first, to: last).month ?? 0
    }

    /// One label every month reads up to a year and a half; past that, every few.
    private func monthLabelStride(_ months: Int) -> Int {
        switch months {
        case ..<19: return 1
        case ..<37: return 3
        default: return 6
        }
    }

    private func accessibilitySeries(_ buckets: [VolumeExplorer.Bucket]) -> ChartAccessibility.Series {
        ChartAccessibility.Series(
            points: buckets.map {
                ChartAccessibility.Point(label: periodLabel($0), value: displayValue($0.value(metric)))
            },
            valueAxisLabel: metric.title
        ) { value in
            SpokenMetric.spoken(measurement: axisLabel(value))
        }
    }

    // MARK: Runs in the selected bar

    private func runList(for bucket: VolumeExplorer.Bucket) -> some View {
        let byID = Dictionary(workouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = bucket.runIDs.reversed().compactMap { byID[$0] }
        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(periodLabel(bucket).uppercased())
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer()
                Text(bucketSummary(bucket))
                    .font(.captionStrong)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.xs)

            if listed.isEmpty {
                Text(bucket.start > .now ? "Nothing yet." : "No runs. A \(grouping.noun) off.")
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
                    .padding(AppSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .strideCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(listed.enumerated()), id: \.element.id) { index, workout in
                        NavigationLink {
                            RunSummaryView(workout: workout)
                        } label: {
                            VolumeExplorerRunRow(workout: workout, unit: unit)
                        }
                        .buttonStyle(.plain)
                        if index < listed.count - 1 {
                            Divider().padding(.leading, AppSpacing.lg)
                        }
                    }
                }
                .strideCard()
            }
        }
    }

    private func bucketSummary(_ bucket: VolumeExplorer.Bucket) -> String {
        let runs = bucket.runCount == 1 ? "1 run" : "\(bucket.runCount) runs"
        guard bucket.runCount > 0 else { return runs }
        return "\(runs) · \(bucket.meters.distanceString(unit: unit))"
    }

    private func periodLabel(_ bucket: VolumeExplorer.Bucket) -> String {
        switch grouping {
        case .week:
            return "Week of \(bucket.start.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            return bucket.start.formatted(.dateTime.month(.wide).year())
        }
    }

    // MARK: Units

    /// Base units to what the axis plots: distance in km or mi, time in hours, climb in
    /// metres or feet, runs as a count.
    private func displayValue(_ base: Double) -> Double {
        switch metric {
        case .distance: return base.distanceValue(unit: unit)
        case .time: return base / 3_600
        case .runs: return base
        case .climb: return base.elevationValue(unit: unit)
        }
    }

    /// A base-unit amount, written out for the headline and the list.
    private func format(_ base: Double) -> String {
        switch metric {
        case .distance:
            return base.distanceString(unit: unit)
        case .time:
            let minutes = Int((base / 60).rounded())
            return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        case .runs:
            let count = base.rounded()
            if count == base { return count == 1 ? "1 run" : "\(Int(count)) runs" }
            return String(format: "%.1f runs", base)
        case .climb:
            return base.elevationString(unit: unit)
        }
    }

    /// An axis value (already in display units), written out.
    private func axisLabel(_ value: Double) -> String {
        switch metric {
        case .distance: return String(format: "%.0f %@", value, unit.distanceLabel)
        case .time: return String(format: "%.0f h", value)
        case .runs: return String(format: "%.0f", value)
        case .climb: return String(format: "%.0f %@", value, unit.elevationLabel)
        }
    }
}

// MARK: - Row

/// One run in the selected bar's list: when, what kind, how far and how fast.
private struct VolumeExplorerRunRow: View {
    let workout: RunWorkout
    let unit: UnitPreference

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            StrideIcon(name: workout.workoutType.strideIcon, size: 18, color: workout.workoutType.color)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.workoutType.localizedName)
                    .font(.bodyStrong)
                    .foregroundStyle(.primary)
                Text(workout.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppSpacing.sm)
            VStack(alignment: .trailing, spacing: 2) {
                Text(workout.distanceMeters.distanceString(unit: unit))
                    .font(.bodyStrong.monospacedDigit())
                    .foregroundStyle(.primary)
                Text(workout.averagePaceSecondsPerKm.paceString(unit: unit))
                    .font(.dsCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            StrideIcon(name: .chevronRight, size: 12, color: .secondary, strokeWeight: 2)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the run")
    }
}

// MARK: - Labels

extension VolumeExplorer.Metric {
    var title: String {
        switch self {
        case .distance: return String(localized: "Distance")
        case .time: return String(localized: "Time")
        case .runs: return String(localized: "Runs")
        case .climb: return String(localized: "Climb")
        }
    }
}

extension VolumeExplorer.Grouping {
    var title: String {
        switch self {
        case .week: return String(localized: "Weekly")
        case .month: return String(localized: "Monthly")
        }
    }

    var noun: String {
        switch self {
        case .week: return String(localized: "week")
        case .month: return String(localized: "month")
        }
    }
}

extension VolumeExplorer.Window {
    /// "3 months", for "Last 3 months" and "the 3 months before".
    var spokenLength: String {
        switch self {
        case .month: return String(localized: "month")
        case .threeMonths: return String(localized: "3 months")
        case .sixMonths: return String(localized: "6 months")
        case .year: return String(localized: "year")
        case .all: return String(localized: "all time")
        }
    }
}
