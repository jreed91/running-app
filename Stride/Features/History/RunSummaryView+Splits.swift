import SwiftUI
import Charts

// Part of `RunSummaryView` (D1).
// The splits card: the tab row, the pace/heart-rate/elevation charts behind it, their
// spoken summaries (N18), and the splits table.

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
        return "Above the dashed line ran faster than this run's \(pace) average"
    }

    /// The splits card: a tab row that actually switches the chart under it.
    ///
    /// The three tabs were previously a static picture with all three charts stacked
    /// below regardless of which one appeared selected (N22).
    var splitsSection: some View {
        let metric = SplitChartMetric.resolved(selection: selectedSplitMetric, in: availableSplitMetrics)
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "Splits")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    // "Pace per 0.1 mi" on a subdivided run: the heading names what a bar
                    // covers, which is no longer always the runner's whole unit (N34).
                    Text(metric.heading(bucket: chartedSplits.bucketLabel))
                        .font(.dsFootnote.weight(.bold))
                    Spacer()
                    if availableSplitMetrics.count > 1 {
                        ForEach(availableSplitMetrics, id: \.self) { option in
                            splitTab(option, active: option == metric)
                        }
                    }
                }
                switch metric {
                case .pace:      splitPaceChart
                case .heartRate: splitHRChart
                case .elevation: splitElevationChart
                }
                Text(splitFootnote(metric)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(AppSpacing.lg)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
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

    /// This run's average split pace, the line the pace bars are drawn against.
    private var averageSplitPace: Double? {
        SplitPaceStats.averagePaceSecondsPerKm(chartedSplits.splits)
    }

    private var splitPaceYDomain: AutomaticScaleDomain {
        chartedSplits.splits.count > 1 && averageSplitPace != nil
            ? .automatic(includesZero: false, reversed: true)
            : .automatic
    }

    /// Pace per split, as deviation from the run's own average.
    ///
    /// This was zero-anchored absolute-pace bars, which is close to unreadable for pace: a
    /// 30-second spread between the fastest and slowest split is a few percent of a bar
    /// that starts at 0:00, so every split looked identical — and because a bigger number
    /// means a slower split, the tallest bar was the *worst* one. Bars now run from the
    /// average pace to each split's pace on a reversed, zero-free scale, so faster splits
    /// rise above the dashed average line and slower ones hang below it, coloured to match.
    ///
    /// Axis labels come from the bucket's cumulative distance in the charted unit, so a
    /// mile-bucketed run reads "4", a mile run charted on tenths reads "0.4", and a legacy
    /// kilometre-bucketed one still counts kilometres.
    private var splitPaceChart: some View {
        let splits = chartedSplits.splits
        // Deviation bars need something to deviate from, and a lone split is its own
        // average — that run keeps a plain zero-anchored bar, which is honest when there is
        // nothing to compare it with.
        let average = splits.count > 1 ? averageSplitPace : nil
        return Chart {
            ForEach(splits, id: \.kilometer) { split in
                let tone = splitPaceTone(split.paceSecondsPerKm, average: average)
                    .opacity(selectedSplitPaceKm == nil || selectedSplitPaceKm == split.kilometer ? 1.0 : 0.4)
                if let average {
                    BarMark(
                        x: .value(splitLabelUpper, split.kilometer),
                        yStart: .value("Average", average),
                        yEnd: .value("Pace", split.paceSecondsPerKm),
                        width: .ratio(0.62)
                    )
                    .foregroundStyle(tone)
                    .cornerRadius(AppRadius.micro)
                } else {
                    BarMark(
                        x: .value(splitLabelUpper, split.kilometer),
                        y: .value("Pace", split.paceSecondsPerKm),
                        width: .ratio(0.62)
                    )
                    .foregroundStyle(tone)
                    .cornerRadius(AppRadius.micro)
                }
            }

            if let average {
                // Deliberately unlabelled inside the plot: an annotation pinned to the line
                // collides with whichever bar happens to sit at that edge. The footnote
                // under the chart names the line and its pace instead.
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            if let bucket = selectedSplitPaceKm, let split = chartedSplit(forBucket: bucket) {
                RuleMark(x: .value(splitLabelUpper, bucket))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .annotation(
                        position: .top,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        splitPaceTooltip(split, average: average)
                    }
            }
        }
        .frame(height: 140)
        // Zero is meaningless for a pace comparison, and reversing the axis puts the faster
        // splits on top. The single-bar fallback keeps the plain upright scale, where a bar
        // hanging from the top edge would just look broken.
        .chartYScale(domain: splitPaceYDomain)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let secs = value.as(Double.self) {
                        Text(secs.paceValueString(unit: appSettings.unitPreference))
                    }
                }
            }
        }
        .chartXAxis { splitXAxis }
        .chartXSelection(value: $selectedSplitPaceKm)
        .chartAccessibility("Split pace chart", splitPaceSummary)
    }

    private func splitPaceTooltip(_ split: Split, average: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(splitTooltipTitle(split))
                .font(.caption2).foregroundStyle(.secondary)
            Text(split.paceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                .font(.caption).bold()
            if let average {
                Text(
                    SplitPaceStats.deltaLabel(
                        pace: split.paceSecondsPerKm,
                        average: average,
                        unit: appSettings.unitPreference
                    )
                )
                .font(.caption2)
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
    /// against, which is exactly what the bars show sighted users.
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
                .foregroundStyle(.zoneInterval)
                PointMark(
                    x: .value(splitLabelUpper, split.kilometer),
                    y: .value("bpm", split.heartRate ?? 0)
                )
                .foregroundStyle(.zoneInterval)
                .symbolSize(selected?.kilometer == split.kilometer ? 80 : 36)
            }
            if let split = selected, let hr = split.heartRate {
                RuleMark(x: .value(splitLabelUpper, split.kilometer))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .annotation(
                        position: .top,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(splitTooltipTitle(split))
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("\(Int(hr)) bpm")
                                .font(.caption).bold()
                        }
                        .padding(.horizontal, AppSpacing.sm).padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.xs))
                    }
            }
        }
        .frame(height: 120)
        .chartYAxisLabel("bpm")
        // Every bucket of the run, banded — the same x axis the pace and elevation charts
        // get for free from their `BarMark`s. It keeps the three tabs in step (a bucket sits
        // at the same place whichever one is showing, and a missing reading reads as a gap
        // rather than being closed up), and it makes the selection snap to a bucket instead
        // of reporting a fraction between two of them.
        .chartXScale(domain: chartedSplits.splits.map(\.kilometer), type: .category)
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
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .annotation(
                        position: .top,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(splitTooltipTitle(split))
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("\(gain >= 0 ? "+" : "")\(Int(gain)) \(appSettings.unitPreference.elevationLabel)")
                                .font(.caption).bold()
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
    var splitsTable: some View {
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
        .padding(AppSpacing.lg)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
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
}
