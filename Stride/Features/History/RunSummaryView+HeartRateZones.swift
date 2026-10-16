import SwiftUI

// Part of `RunSummaryView` (D1).
// Time-in-zone for this run. The samples are loaded (and backfilled for older imports)
// in the main file's `loadHeartRateZones`; the zone maths lives in `HeartRateZoneService`.

extension RunSummaryView {

    // MARK: Heart-rate zone section

    var heartRateZoneSection: some View {
        let total = zoneSlices.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 12) {
            Text("TIME IN HEART-RATE ZONES")
                .font(.sectionHeader).foregroundStyle(.secondary).padding(.horizontal, AppSpacing.xs)
            // Stacked proportion bar. `GeometryReader` stays here deliberately (U7): five
            // segments each need a *width* from the container, and none of the modern
            // replacements set a frame — `visualEffect` only applies effects, and
            // `containerRelativeFrame` measures the scroll view rather than this card.
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(zoneSlices) { slice in
                        if slice.seconds > 0 {
                            slice.zone.color
                                .frame(width: max(3, geo.size.width * CGFloat(slice.seconds / max(total, 1))))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            // Per-zone rows, hardest zone first.
            VStack(spacing: 8) {
                ForEach(zoneSlices.reversed()) { slice in
                    zoneRow(slice, total: total)
                }
            }
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.md)
    }

    private func zoneRow(_ slice: HRZoneSlice, total: Double) -> some View {
        let pct = total > 0 ? slice.seconds / total : 0
        let bounds = maxHeartRate.map { HeartRateZoneService.bounds(for: slice.zone, maxHR: $0) }
        return HStack(spacing: 10) {
            Circle().fill(slice.zone.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(slice.zone.displayTitle).font(.caption).bold()
                if let bounds {
                    Text("\(bounds.lower)–\(bounds.upper) bpm")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(slice.seconds.durationString).font(.caption).monospacedDigit()
            Text("\(Int((pct * 100).rounded()))%")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slice.zone.displayTitle), \(Int((pct * 100).rounded())) percent")
    }
}
