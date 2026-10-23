import SwiftUI
import Charts

// Part of `RunSummaryView` (D1).
// The splits card: the metric control, the pace/heart-rate/elevation charts behind it,
// their spoken summaries (N18), and the splits table under them.

extension RunSummaryView {

    // MARK: Charted series

    /// The splits the charts plot, and what one of them covers.
    ///
    /// Not the run's stored `splits`: those close on a whole kilometre or mile, so a one-mile
    /// run charted exactly one marker and a 5K charted three (N34). `SplitChartSeries`
    /// re-buckets a short run's recorded distance readings into fractions of the unit and
    /// falls back to the stored splits for everything else — including every run recorded
    /// before those readings were kept.
    ///
    /// Resolved once per run into `@State` rather than recomputed in `body`: re-bucketing
    /// decodes a few thousand readings, and dragging across a chart re-evaluates `body` on
    /// every touch.
    var chartedSplits: SplitChartSeries.Resolved {
        resolvedSplitSeries
            ?? SplitChartSeries.Resolved(splits: workout.splits, fraction: 1, unit: workout.splitUnit)
    }

    /// Recomputes `chartedSplits`. Called on open and again after a backfill, which is what
    /// gives an older imported run its readings.
    func resolveSplitChartSeries() {
        resolvedSplitSeries = SplitChartSeries.resolve(for: workout, unit: appSettings.unitPreference)
    }

    // MARK: Splits section

    /// The metrics this run's splits can chart. The rule lives in `SplitChartMetric`
    /// (N22/D1) so "does this run carry per-split heart rate or elevation?" can be tested
    /// without the view.
    ///
    /// Asked of the charted series rather than the stored splits, since that is what the
    /// tabs would be switching between.
    var availableSplitMetrics: [SplitChartMetric] {
        SplitChartMetric.available(for: chartedSplits.splits)
    }

    /// The pace chart's footnote names the dashed baseline and its pace, since the line
    /// carries no in-plot label. Only this run knows its own average, so the metric's
    /// static footnote stands in when there isn't one.
    private func splitFootnote(_ metric: SplitChartMetric) -> String {
        guard metric == .pace, let average = averageSplitPace else { return metric.footnote }
        let pace = average.paceString(unit: appSettings.unitPreference)
        return "Higher is faster. The dashed line is this run's \(pace) average"
    }

    /// The splits card: the chart and, under it, the table, so the two readings of the same
    /// splits sit in one card rather than two back to back.
    ///
    /// The card can outlive the table: a run under one whole unit has no stored splits to
    /// tabulate, but its recorded readings still bucket into a chart worth showing (N34).
    @ViewBuilder
    var splitsCard: some View {
        if !chartedSplits.splits.isEmpty || !workout.splits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 12) {
                    if !chartedSplits.splits.isEmpty {
                        splitsChart
                    }
                    if !chartedSplits.splits.isEmpty, !workout.splits.isEmpty {
                        Divider()
                    }
                    if !workout.splits.isEmpty {
                        splitsTable
                    }
                }
                .padding(AppSpacing.lg)
                .strideCard()
            }
        }
    }

    /// The metric control and the chart it switches.
    ///
    /// The three tabs were previously a static picture with all three charts stacked
    /// below regardless of which one appeared selected (N22).
    private var splitsChart: some View {
        let metric = SplitChartMetric.resolved(selection: selectedSplitMetric, in: availableSplitMetrics)
        return VStack(alignment: .leading, spacing: 12) {
            if availableSplitMetrics.count > 1 {
                // Bound to the resolved metric, so the highlighted segment is always the
                // chart on screen even when the stored choice isn't available on this run.
                StrideSegmentedControl(
                    selection: Binding(
                        get: { metric },
                        set: { selectedSplitMetric = $0 }
                    ),
                    options: availableSplitMetrics
                ) { option in
                    Text(option.tabTitle)
                }
            }
            // "Pace per 0.1 mi" on a subdivided run: the heading names what a bar
            // covers, which is no longer always the runner's whole unit (N34).
            Text(metric.heading(bucket: chartedSplits.bucketLabel))
                .font(.dsFootnote.weight(.bold))
            switch metric {
            case .pace:      splitPaceChart
            case .heartRate: splitHRChart
            case .elevation: splitElevationChart
            }
            Text(splitFootnote(metric)).font(.dsCaption).foregroundStyle(.secondary)
        }
    }

    /// The chart's selection rule: dashed brand, the same as the Progress charts.
    private var selectionRuleColor: Color { Color.brand.opacity(0.55) }
    private var selectionRuleStyle: StrokeStyle {
        StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4])
    }

    // MARK: Chart axis

    /// The charted split with this bucket number.
    private func chartedSplit(forBucket bucket: Int) -> Split? {
        chartedSplits.splits.first { $0.kilometer == bucket }
    }

    /// Distance covered by the end of a bucket, in the charted unit: "3" on whole-unit
    /// splits, "0.4" on tenths.
    ///
    /// The x axis plots bucket numbers because that is what a `Split` carries, but a bucket
    /// number means nothing once a bucket is a tenth of a mile — so every label, tooltip and
    /// spoken point names the distance instead.
    private func splitDistanceLabel(_ split: Split) -> String {
        // A split with no recorded cumulative distance falls back to its bucket number,
        // which is what the axis showed before it named distances at all.
        guard split.cumulativeDistanceMeters > 0 else { return "\(split.kilometer)" }
        return SplitChartSeries.axisLabel(
            cumulativeMeters: split.cumulativeDistanceMeters,
            unit: chartedSplits.unit,
            fraction: chartedSplits.fraction
        )
    }

    private func splitDistanceLabel(forBucket bucket: Int) -> String? {
        chartedSplit(forBucket: bucket).map { splitDistanceLabel($0) }
    }

    /// "0.4 mi" — a bucket named the way the axis names it, plus the unit.
    private func splitTooltipTitle(_ split: Split) -> String {
        "\(splitDistanceLabel(split)) \(chartedSplits.unit.distanceLabel)"
    }

    /// Buckets to label on the x axis: roughly five, evenly spaced, counted back from the
    /// last so the run's finishing distance is always one of them.
    private var splitAxisTicks: [Int] {
        let splits = chartedSplits.splits
        guard !splits.isEmpty else { return [] }
        let step = max(1, Int((Double(splits.count) / 5).rounded(.up)))
        var ticks: [Int] = []
        var index = splits.count - 1
        while index >= 0 {
            ticks.append(splits[index].kilometer)
            index -= step
        }
        ticks.reverse()
        return ticks
    }

    /// Shared by all three charts so a bar, a point and a tooltip all name the same bucket
    /// the same way.
    private var splitXAxis: some AxisContent {
        AxisMarks(values: splitAxisTicks) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let bucket = value.as(Int.self), let label = splitDistanceLabel(forBucket: bucket) {
                    Text(label)
                }
            }
        }
    }

    // MARK: Split pace chart

    /// This run's average split pace, the dashed line the pace line is read against.
    private var averageSplitPace: Double? {
        SplitPaceStats.averagePaceSecondsPerKm(chartedSplits.splits)
    }

    /// The split the pace chart's tooltip is showing. Snapped to the nearest bucket for the
    /// same reason as `selectedHeartRateSplit`: a chart drawn from `LineMark`/`PointMark`
    /// reports selections between buckets.
    private var selectedPaceSplit: Split? {
        guard let bucket = selectedSplitPaceKm else { return nil }
        return SplitChartSeries.nearestSplit(to: bucket, in: chartedSplits.splits)
    }

    /// Pace through the run as a line, against the run's own average, opened by a one-line
    /// read of how the second half compared with the first.
    ///
    /// This was deviation bars on a reversed, auto-fitted scale, and on device (a 1.5 mi
    /// run on quarter-mile buckets) it drew no visible bars and an axis from 5:21 to 21:27:
    /// one slow bucket stretched the scale, and the automatic ticks fell on round seconds
    /// per kilometre, which read as odd paces in miles. Now:
    ///
    /// - The y value is seconds faster than the average, so up is faster without reversing
    ///   the scale, and the dashed average line sits at zero, mid-chart.
    /// - The domain is set from the data (`SplitPaceStats.chartDomain`): at least ±15 s/km
    ///   so an even run looks even, at most ±90 s/km so a stop does not flatten the rest. A
    ///   bucket past that is drawn on the edge; its tooltip gives the real pace.
    /// - Three axis labels: the fast edge, the average and the slow edge, as paces.
    /// - A line in the route gradient rather than bars, since the question is how pace moved
    ///   through the run; each bucket keeps a dot coloured faster/on pace/slower.
    @ViewBuilder
    private var splitPaceChart: some View {
        let splits = chartedSplits.splits
        if let average = averageSplitPace {
            let domain = SplitPaceStats.chartDomain(paces: splits.map(\.paceSecondsPerKm), average: average)
            let half = domain.upperBound - average
            let selected = selectedPaceSplit
            VStack(alignment: .leading, spacing: 8) {
                if let shape = SplitPaceStats.shape(splits, unit: appSettings.unitPreference) {
                    Text(SplitPaceStats.shapeHeadline(shape, unit: appSettings.unitPreference))
                        .font(.dsHeadline)
                }
                Chart {
                    // Deliberately unlabelled inside the plot; the footnote names it.
                    RuleMark(y: .value("Average", 0.0))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    ForEach(splits, id: \.kilometer) { split in
                        let faster = average - SplitPaceStats.clamped(split.paceSecondsPerKm, to: domain)
                        LineMark(
                            x: .value(splitLabelUpper, split.kilometer),
                            y: .value("Faster than average", faster)
                        )
                        .foregroundStyle(.route)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                        PointMark(
                            x: .value(splitLabelUpper, split.kilometer),
                            y: .value("Faster than average", faster)
                        )
                        .foregroundStyle(splitPaceTone(split.paceSecondsPerKm, average: average))
                        .symbolSize(selected?.kilometer == split.kilometer ? 80 : 30)
                    }

                    if let split = selected {
                        RuleMark(x: .value(splitLabelUpper, split.kilometer))
                            .foregroundStyle(selectionRuleColor)
                            .lineStyle(selectionRuleStyle)
                            .annotation(
                                position: .top,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                splitPaceTooltip(split, average: splits.count > 1 ? average : nil)
                            }
                    }
                }
                .frame(height: 150)
                .chartYScale(domain: -half...half)
                .chartYAxis {
                    AxisMarks(values: [-half, 0, half]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            // Back from "seconds faster" to the pace at that height.
                            if let faster = value.as(Double.self) {
                                Text((average - faster).paceValueString(unit: appSettings.unitPreference))
                            }
                        }
                    }
                }
                .chartXAxis { splitXAxis }
                .chartXSelection(value: $selectedSplitPaceKm)
                .chartAccessibility("Split pace chart", splitPaceSummary)
            }
        }
    }

    private func splitPaceTooltip(_ split: Split, average: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(splitTooltipTitle(split))
                .font(.dsCaption2).foregroundStyle(.secondary)
            Text(split.paceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                .font(.dsCaption.weight(.bold))
            if let average {
                Text(
                    SplitPaceStats.deltaLabel(
                        pace: split.paceSecondsPerKm,
                        average: average,
                        unit: appSettings.unitPreference
                    )
                )
                .font(.dsCaption2)
                .foregroundStyle(splitPaceTone(split.paceSecondsPerKm, average: average))
            }
        }
        .padding(.horizontal, AppSpacing.sm).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.xs))
    }

    /// Faster than this run's average reads as a gain, slower as a caution, and anything
    /// inside the on-pace tolerance stays neutral so an even run looks even.
    private func splitPaceTone(_ pace: Double, average: Double?) -> Color {
        guard let average else { return .brand }
        switch SplitPaceStats.comparison(pace: pace, average: average, unit: appSettings.unitPreference) {
        case .faster: return .success
        case .onPace: return .brand
        case .slower: return .warning
        }
    }

    // MARK: Split chart accessibility (N18)

    /// Accessibility points for a split chart: each bucket labelled by the distance it ends
    /// at ("0.4 mi"), with the value the chart plots.
    private func splitPoints(
        _ splits: [Split],
        value: (Split) -> Double
    ) -> [ChartAccessibility.Point] {
        splits.map { ChartAccessibility.Point(label: splitTooltipTitle($0), value: value($0)) }
    }

    /// The chart is read against the run's average now, so the spoken summary names it
    /// first — otherwise a VoiceOver user gets the split values with nothing to judge them
    /// against, which is exactly what the dashed line shows sighted users.
    private var splitPaceSummary: String {
        let values = ChartAccessibility.summary(splitPoints(chartedSplits.splits) { $0.paceSecondsPerKm }) {
            SpokenMetric.spoken(measurement: $0.paceString(unit: appSettings.unitPreference))
        }
        guard let average = averageSplitPace else { return values }
        let spokenAverage = SpokenMetric.spoken(measurement: average.paceString(unit: appSettings.unitPreference))
        return "Average \(spokenAverage). \(values)"
    }

    private func splitHeartRateSummary(_ splits: [Split]) -> String {
        ChartAccessibility.summary(splitPoints(splits) { $0.heartRate ?? 0 }) {
            "\(Int($0)) beats per minute"
        }
    }

    private var splitElevationSummary: String {
        ChartAccessibility.summary(
            splitPoints(chartedSplits.splits) {
                $0.elevationGainMeters.elevationValue(unit: appSettings.unitPreference)
            }
        ) {
            SpokenMetric.spoken(value: "\(Int($0))", unit: appSettings.unitPreference.elevationLabel)
        }
    }

    // MARK: Split HR chart

    /// The splits the HR chart plots: only the buckets that carry a reading, since a run
    /// can lose its strap partway and a gap is more honest than a line drawn through zero.
    private var heartRateSplits: [Split] {
        chartedSplits.splits.filter { $0.heartRate != nil }
    }

    /// The split the HR chart's tooltip is showing, resolved from the raw selection.
    ///
    /// Not an exact bucket match, the way the pace and elevation charts get away with. Those
    /// two are drawn from `BarMark`s, which band their x axis, so a selection always lands on
    /// a bucket that exists. This chart is drawn only from `LineMark`/`PointMark`, so its x
    /// axis is continuous and `chartXSelection` reports the position between two markers —
    /// which matched no split, and left the chart with a hover that highlighted nothing and
    /// showed no value. `nearestSplit` snaps to the marker beside the finger instead, and
    /// snaps within the plotted splits so a bucket with no reading resolves to one that has
    /// it rather than to nothing.
    private var selectedHeartRateSplit: Split? {
        guard let bucket = selectedSplitHRKm else { return nil }
        return SplitChartSeries.nearestSplit(to: bucket, in: heartRateSplits)
    }

    private var splitHRChart: some View {
        let hrSplits = heartRateSplits
        let selected = selectedHeartRateSplit
        return Chart {
            ForEach(hrSplits, id: \.kilometer) { split in
                LineMark(
                    x: .value(splitLabelUpper, split.kilometer),
                    y: .value("bpm", split.heartRate ?? 0)
                )
                // Brand, not a zone colour: this line is every split's heart rate, not
                // time in one zone.
                .foregroundStyle(.brand)
                PointMark(
                    x: .value(splitLabelUpper, split.kilometer),
                    y: .value("bpm", split.heartRate ?? 0)
                )
                .foregroundStyle(.brand)
                .symbolSize(selected?.kilometer == split.kilometer ? 80 : 36)
            }
            if let split = selected, let hr = split.heartRate {
                RuleMark(x: .value(splitLabelUpper, split.kilometer))
                    .foregroundStyle(selectionRuleColor)
                    .lineStyle(selectionRuleStyle)
                    .annotation(
                        position: .top,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(splitTooltipTitle(split))
                                .font(.dsCaption2).foregroundStyle(.secondary)
                            Text("\(Int(hr)) bpm")
                                .font(.dsCaption.weight(.bold))
                        }
                        .padding(.horizontal, AppSpacing.sm).padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.xs))
                    }
            }
        }
        .frame(height: 120)
        .chartYAxisLabel("bpm")
        // The x scale is left to Charts to infer, as it is on the other two tabs. Forcing a
        // categorical one here — to band the axis the way the pace and elevation charts are
        // banded by their `BarMark`s — crashed at runtime: bucket numbers are `Int`, whose
        // primitive plottable value is continuous, and a category scale over them is not a
        // combination Charts accepts. Snapping the selection in `selectedHeartRateSplit` is
        // what makes the hover work, and it needs nothing from the scale.
        .chartXAxis { splitXAxis }
        .chartXSelection(value: $selectedSplitHRKm)
        .chartAccessibility("Split heart rate chart", splitHeartRateSummary(hrSplits))
    }

    // MARK: Split elevation chart

    private var splitElevationChart: some View {
        Chart {
            ForEach(chartedSplits.splits, id: \.kilometer) { split in
                let gain = split.elevationGainMeters.elevationValue(unit: appSettings.unitPreference)
                BarMark(
                    x: .value(splitLabelUpper, split.kilometer),
                    y: .value(appSettings.unitPreference.elevationLabel, gain)
                )
                .foregroundStyle(
                    (gain >= 0 ? Color.success : Color.destructive)
                        .opacity(selectedSplitElevKm == nil || selectedSplitElevKm == split.kilometer ? 1.0 : 0.5)
                )
            }
            if let bucket = selectedSplitElevKm, let split = chartedSplit(forBucket: bucket) {
                let gain = split.elevationGainMeters.elevationValue(unit: appSettings.unitPreference)
                RuleMark(x: .value(splitLabelUpper, bucket))
                    .foregroundStyle(selectionRuleColor)
                    .lineStyle(selectionRuleStyle)
                    .annotation(
                        position: .top,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(splitTooltipTitle(split))
                                .font(.dsCaption2).foregroundStyle(.secondary)
                            Text("\(gain >= 0 ? "+" : "")\(Int(gain)) \(appSettings.unitPreference.elevationLabel)")
                                .font(.dsCaption.weight(.bold))
                        }
                        .padding(.horizontal, AppSpacing.sm).padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.xs))
                    }
            }
        }
        .frame(height: 100)
        .chartYAxisLabel(appSettings.unitPreference.elevationLabel)
        .chartXAxis { splitXAxis }
        .chartXSelection(value: $selectedSplitElevKm)
        .chartAccessibility("Split elevation chart", splitElevationSummary)
    }

    // MARK: Splits table

    /// The table stays on the run's stored whole-unit splits even when the charts above it
    /// are drawn on fractions: "4:12 for mile 3" is the number a runner reads off a table,
    /// and forty rows of tenth-mile paces is not a table anyone reads.
    ///
    /// No card of its own: it sits under the chart in `splitsCard`.
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
            .font(.dsCaption)
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
                        Text("\(Int(hr))").foregroundStyle(.primary)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 60, alignment: .trailing)
                .font(.dsCaption)
            }
            elevationCell(split.elevationGainMeters)
                .frame(width: 60, alignment: .trailing)
                .font(.dsCaption)
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
}
