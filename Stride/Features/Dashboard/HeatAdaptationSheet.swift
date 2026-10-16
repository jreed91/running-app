import SwiftUI
import SwiftData

// MARK: - HeatAdaptationSheet

/// Shows exactly what accepting the heat adaptation would do to tomorrow's session, then
/// does it.
///
/// The change is listed line by line before it is applied, and the lines come from
/// ``HeatAdaptationPolicy/adaptation(for:tier:unit:)`` — the same value that performs the
/// edit. A summary written separately from the mutation is a summary that drifts from it,
/// and this is a screen whose entire job is to be trusted about what it is about to change.
struct HeatAdaptationSheet: View {
    let advisory: HeatAdvisory
    /// The plan row to rewrite. `nil` when the session has since been deleted or
    /// completed, which leaves the sheet in a read-only "here's the forecast" state rather
    /// than offering a button that would do nothing.
    let workout: ScheduledWorkout?
    let unit: UnitPreference
    /// Called after the adaptation is applied, and when the runner declines it. Both are
    /// answers, and both stop the card and the notification asking again at this severity.
    let onAnswered: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    private var adaptation: HeatAdaptationPolicy.Adaptation? {
        workout.map {
            HeatAdaptationPolicy.adaptation(for: $0, tier: advisory.tier, unit: unit)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    forecastSection
                    if let adaptation, adaptation.changesAnything {
                        changesSection(adaptation)
                    }
                    if let cooler = advisory.cooler {
                        coolerSection(cooler)
                    }
                    guidanceSection
                    disclaimer
                }
                .padding(AppSpacing.lg)
            }
            .background(Color.surfacePrimary)
            .navigationTitle("Heat check")
            .navigationBarTitleDisplayMode(.inline)
            // No cancellation item, and the presenter disables drag-to-dismiss: this
            // sheet is a decision, and the two buttons in `actionBar` are the only way
            // out of it. "Run it as planned" is a real answer, not a way of avoiding one
            // — the runner who chooses it has read the forecast, which is the whole point
            // of asking the night before.
            .safeAreaInset(edge: .bottom) { actionBar }
        }
    }

    // MARK: - Forecast

    private var forecastSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(advisory.workoutType.localizedName) · \(advisory.plannedStart.formatted(.dateTime.weekday(.wide).hour().minute()))")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                metric(advisory.conditions.feelsLikeString(unit: unit), "Feels like")
                metric(advisory.conditions.dewPointString(unit: unit), "Dew point")
                metric("\(Int(advisory.conditions.humidityPercent.rounded()))%", "Humidity")
            }

            Text(verbatim: expectedCostText)
                .font(.bodyRegular)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.lg)
        .background(sectionBackground)
    }

    /// The headline claim, and the one number the whole feature turns on.
    private var expectedCostText: String {
        guard let band = HeatAdaptationPolicy.paceAdjustmentPercent(for: advisory.tier) else {
            return String(
                localized: """
                    \(advisory.tier.localizedName). Pace targets stop meaning anything in this — \
                    run it entirely on effort, or run it somewhere else.
                    """,
                comment: "Heat sheet summary when conditions are extreme enough to drop pace targets"
            )
        }
        let low = String(format: "%.1f", band.lowerBound)
        let high = String(format: "%.1f", band.upperBound)
        return String(
            localized: """
                \(advisory.tier.localizedName). Expect to run about \(low)–\(high)% slower \
                for the same effort.
                """,
            comment: "Heat sheet summary: the expected pace cost of the conditions"
        )
    }

    // MARK: - Changes

    private func changesSection(_ adaptation: HeatAdaptationPolicy.Adaptation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What changes")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            ForEach(Array(adaptation.changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .top, spacing: 8) {
                    StrideIcon(name: .check, size: 13, color: .brand, strokeWeight: 2.2)
                        .padding(.top, 3)
                    Text(verbatim: change)
                        .font(.bodyRegular)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(sectionBackground)
    }

    // MARK: - Cooler hour

    private func coolerSection(_ cooler: HeatAdvisory.CoolerOption) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A cooler hour")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            // Stated rather than actioned: the app does not know what else is in the
            // runner's day, so moving the session for them would be a guess dressed up as
            // help. Telling them the hour is the part they cannot work out themselves.
            Text("""
                Running at \(cooler.start.formatted(.dateTime.hour().minute())) instead would be \
                \(cooler.conditions.feelsLikeString(unit: unit)) with a \
                \(cooler.conditions.dewPointString(unit: unit)) dew point — \
                \(cooler.tier.localizedName.lowercased()) rather than \
                \(advisory.tier.localizedName.lowercased()).
                """)
                .font(.bodyRegular)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(sectionBackground)
    }

    // MARK: - Guidance

    private var guidanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Out there")
                .strideEyebrow()
                .foregroundStyle(.secondary)

            ForEach(Array(guidance.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 4, height: 4)
                        .padding(.top, 8)
                    Text(verbatim: line)
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(sectionBackground)
    }

    private var guidance: [String] {
        var lines = [
            String(
                localized: """
                    Start hydrated rather than catching up mid-run, and take fluid with you \
                    for anything over an hour.
                    """,
                comment: "Heat guidance line"
            ),
            String(
                localized: "Judge the session on effort and heart rate, not the watch's pace.",
                comment: "Heat guidance line"
            )
        ]
        // Asked of the policy's own table rather than against a number written here, so
        // the line appears exactly when the dew-point scale says the evaporative route is
        // closing — and moves with the table if the evidence does.
        let dewPointTier = HeatAdaptationPolicy.tier(
            for: HeatAdaptationPolicy.dewPointCelsius(for: advisory.conditions),
            on: HeatAdaptationPolicy.dewPointCelsiusThresholds
        )
        if dewPointTier >= .high {
            lines.append(String(
                localized: """
                    The dew point is high enough that sweat won't evaporate well, so add \
                    electrolytes and expect your heart rate to sit higher than usual at any pace.
                    """,
                comment: "Heat guidance line for a high dew point"
            ))
        }
        lines.append(String(
            localized: """
                Stop if you get chills, stop sweating, or your head starts to go — \
                those are heat illness, not toughness.
                """,
            comment: "Heat guidance line about warning signs"
        ))
        return lines
    }

    private var disclaimer: some View {
        Text("""
            These adjustments are a starting point drawn from published heat-running guidance. \
            If you're used to training in this, you may need less of them. Stride isn't a \
            clinician — how you feel out there beats any of it.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private var actionBar: some View {
        VStack(spacing: 8) {
            if let adaptation, adaptation.changesAnything, let workout {
                Button {
                    HeatAdaptationPolicy.apply(adaptation, to: workout)
                    context.saveOrLog("the heat-adapted workout")
                    onAnswered()
                    dismiss()
                } label: {
                    Text("Apply to tomorrow's workout")
                        .font(.dsSubhead.weight(.semibold))
                        .foregroundStyle(.onFill)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.md)
                                .fill(Color.brand)
                        )
                }
                .buttonStyle(.plain)
            }

            Button {
                onAnswered()
                dismiss()
            } label: {
                Text("Run it as planned")
                    .font(.dsSubhead.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .fill(Color.surfaceSecondary)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.lg)
        .background(.bar)
    }

    // MARK: - Styling

    private func metric(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.bodyStrong)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var sectionBackground: some View {
        RoundedRectangle(cornerRadius: AppRadius.lg)
            .fill(Color.surfaceSecondary)
    }
}
