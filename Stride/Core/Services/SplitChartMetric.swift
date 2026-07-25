import Foundation

// MARK: - SplitChartMetric

/// The metrics the run summary's splits card can chart, and which of them a given run
/// actually has data for.
///
/// The tab row used to offer all three unconditionally while stacking all three charts
/// below it regardless of which appeared selected (N22). It is now a real picker, which
/// makes "does this run carry heart rate / elevation per split?" a rule the UI depends
/// on rather than decoration — so it belongs outside the view (D1), where an app-recorded
/// run with no HR strap and an imported run with no elevation series can both be checked.
enum SplitChartMetric: String, CaseIterable, Hashable, Sendable {
    case pace = "Pace"
    case heartRate = "HR"
    case elevation = "Elev"

    /// Label for the metric's tab.
    var tabTitle: String { rawValue }

    /// The line under the chart explaining how to read it.
    var footnote: String {
        switch self {
        case .pace:      return "Lower = faster"
        case .heartRate: return "Average heart rate in each split"
        case .elevation: return "Gain within each split"
        }
    }

    /// The card's heading for this metric, in the runner's distance unit.
    func heading(unit: UnitPreference) -> String {
        switch self {
        case .pace:      return "Pace per \(unit.distanceLabel)"
        case .heartRate: return "Heart rate per \(unit.distanceLabel)"
        case .elevation: return "Elevation per \(unit.distanceLabel)"
        }
    }

    // MARK: Availability

    /// The metrics `splits` can actually chart, in tab order.
    ///
    /// Pace is always offered: a split exists because a distance boundary was crossed at
    /// a known time, so it always has one. Heart rate needs at least one split to carry a
    /// reading — a run recorded without a strap has splits whose `heartRate` is `nil`
    /// throughout. Elevation needs at least one non-zero gain, since a flat run and a run
    /// with no barometer both store zeroes and neither has a chart worth drawing.
    ///
    /// Empty splits yield no metrics at all, which is the caller's signal to hide the
    /// card rather than to render an empty chart.
    static func available(for splits: [Split]) -> [SplitChartMetric] {
        guard !splits.isEmpty else { return [] }

        var metrics: [SplitChartMetric] = [.pace]
        if splits.contains(where: { $0.heartRate != nil }) { metrics.append(.heartRate) }
        if splits.contains(where: { $0.elevationGainMeters != 0 }) { metrics.append(.elevation) }
        return metrics
    }

    /// Resolves the metric to chart: the runner's selection when the run still supports
    /// it, otherwise the first one it does.
    ///
    /// The selection is view state that outlives the data it points at — switching to the
    /// HR tab and then opening a run with no heart rate would otherwise chart a series
    /// that isn't there.
    static func resolved(selection: SplitChartMetric, in available: [SplitChartMetric]) -> SplitChartMetric {
        available.contains(selection) ? selection : (available.first ?? .pace)
    }
}
