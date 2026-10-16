import SwiftUI

// Part of `RunSummaryView` (D1).
// The laps table: the boundaries the runner marked by hand during the run (A2).

extension RunSummaryView {

    /// The laps card, shown only for runs that were actually lapped.
    ///
    /// It sits above the splits rather than below them because a lapped run was lapped
    /// *deliberately* — those boundaries are the ones the runner chose, and the automatic
    /// per-kilometre buckets underneath are the fallback reading. Runs with no laps (most
    /// of them) show nothing here at all rather than a card explaining its own absence.
    var lapsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "Laps")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("LAP")
                        .frame(width: 36, alignment: .leading)
                    Spacer()
                    Text("TIME").frame(width: 72, alignment: .trailing)
                    Text(appSettings.unitPreference.splitLabel)
                        .frame(width: 60, alignment: .trailing)
                    Text("PACE").frame(width: 72, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                ForEach(workout.laps, id: \.number) { lap in
                    lapRow(lap)
                    Divider()
                }
            }
            .padding(AppSpacing.lg)
            .strideCard(cornerRadius: AppRadius.md)
        }
    }

    private func lapRow(_ lap: Lap) -> some View {
        HStack {
            Text("\(lap.number)")
                .frame(width: 36, alignment: .leading)
                .font(.bodyRegular)
            Spacer()
            Text(lap.durationSeconds.durationString)
                .frame(width: 72, alignment: .trailing)
                .font(.dsCaption.monospaced())
                .foregroundStyle(.secondary)
            Text(String(format: "%.2f", lap.distanceMeters.distanceValue(unit: appSettings.unitPreference)))
                .frame(width: 60, alignment: .trailing)
                .font(.dsCaption.monospaced())
                .foregroundStyle(.secondary)
            Text(lap.paceSecondsPerKm.paceValueString(unit: appSettings.unitPreference))
                .frame(width: 72, alignment: .trailing)
                .font(.bodyStrong)
        }
        // One element per row: read cell by cell this is four unlabelled numbers with no
        // hint which is which (N18).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "Lap \(lap.number)", comment: "Accessibility label for one lap row")
        )
        .accessibilityValue(lapSpokenValue(lap))
    }

    private func lapSpokenValue(_ lap: Lap) -> String {
        let unit = appSettings.unitPreference
        let distance = SpokenMetric.spoken(measurement: lap.distanceMeters.distanceString(unit: unit))
        let duration = lap.durationSeconds.durationString
        let pace = SpokenMetric.spoken(measurement: lap.paceSecondsPerKm.paceString(unit: unit))
        return String(
            localized: "\(distance) in \(duration), \(pace)",
            comment: "Spoken summary of one lap: distance, duration, pace"
        )
    }
}
