import SwiftUI
import Charts

// Part of `RunSummaryView` (D1).
// The splits card: the tab row, the pace/heart-rate/elevation charts behind it, their
// spoken summaries (N18), and the splits table.

extension RunSummaryView {

    // MARK: Splits section

    /// The metrics this run's splits can chart. The rule lives in `SplitChartMetric`
    /// (N22/D1) so "does this run carry per-split heart rate or elevation?" can be tested
    /// without the view.
    var availableSplitMetrics: [SplitChartMetric] {
        SplitChartMetric.available(for: workout.splits)
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
                    Text(metric.heading(unit: appSettings.unitPreference))
                        .font(.system(size: 13, weight: .bold))
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
            .padding(16)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Split pace chart

    /// This run's average split pace, the line the pace bars are drawn against.
    private var averageSplitPace: Double? {
        SplitPaceStats.averagePaceSecondsPerKm(workout.splits)
    }

    private var splitPaceYDomain: AutomaticScaleDomain {
        workout.splits.count > 1 && averageSplitPace != nil
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
    /// Bucket labels come from the run's stored `splitUnit`, so a mile-bucketed run reads
    /// "mi 4" and a legacy kilometre-bucketed one still reads "km 4".
    private var splitPaceChart: some View {
        // Deviation bars need something to deviate from, and a lone split is its own
        // average — that run keeps a plain zero-anchored bar, which is honest when there is
        // nothing to compare it with.
        let average = workout.splits.count > 1 ? averageSplitPace : nil
        return Chart {
            ForEach(workout.splits, id: \.kilometer) { split in
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
                    .cornerRadius(3)
                } else {
                    BarMark(
                        x: .value(splitLabelUpper, split.kilometer),
                        y: .value("Pace", split.paceSecondsPerKm),
                        width: .ratio(0.62)
                    )
                    .foregroundStyle(tone)
                    .cornerRadius(3)
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

            if let km = selectedSplitPaceKm, let split = split(forKm: km) {
                RuleMark(x: .value(splitLabelUpper, km))
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
        .chartXSelection(value: $selectedSplitPaceKm)
        .chartAccessibility("Split pace chart", splitPaceSummary)
    }

    private func splitPaceTooltip(_ split: Split, average: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(splitLabel) \(split.kilometer)")
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
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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

    /// Accessibility points for a split chart: each bucket labelled the way the axis
    /// labels it ("km 3"), with the value the chart plots.
    private func splitPoints(
        _ splits: [Split],
        value: (Split) -> Double
    ) -> [ChartAccessibility.Point] {
        splits.map { ChartAccessibility.Point(label: "\(splitLabel) \($0.kilometer)", value: value($0)) }
    }

    /// The chart is read against the run's average now, so the spoken summary names it
    /// first — otherwise a VoiceOver user gets the split values with nothing to judge them
    /// against, which is exactly what the bars show sighted users.
    private var splitPaceSummary: String {
        let values = ChartAccessibility.summary(splitPoints(workout.splits) { $0.paceSecondsPerKm }) {
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
            splitPoints(workout.splits) {
                $0.elevationGainMeters.elevationValue(unit: appSettings.unitPreference)
            }
        ) {
            SpokenMetric.spoken(value: "\(Int($0))", unit: appSettings.unitPreference.elevationLabel)
        }
    }

    // MARK: Split HR chart

    private var splitHRChart: some View {
        let hrSplits = workout.splits.filter { $0.heartRate != nil }
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
                .symbolSize(selectedSplitHRKm == split.kilometer ? 80 : 36)
            }
            if let km = selectedSplitHRKm, let split = split(forKm: km), let hr = split.heartRate {
                RuleMark(x: .value(splitLabelUpper, km))
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
        .chartAccessibility("Split heart rate chart", splitHeartRateSummary(hrSplits))
    }

    // MARK: Split elevation chart

    private var splitElevationChart: some View {
        Chart {
            ForEach(workout.splits, id: \.kilometer) { split in
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
            if let km = selectedSplitElevKm, let split = split(forKm: km) {
                let gain = split.elevationGainMeters.elevationValue(unit: appSettings.unitPreference)
                RuleMark(x: .value(splitLabelUpper, km))
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
        .chartAccessibility("Split elevation chart", splitElevationSummary)
    }

    // MARK: Splits table

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
}
