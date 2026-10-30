import SwiftUI

// Plan's reference pages: the rows that open them and the Pace Insights card. Moved out of
// `PlanTabView.swift` when Race Insights joined Plan, to keep that file under the length
// limit.

// MARK: - Pace Insights Card

/// The row on Plan that opens the pace insights page.
struct PaceInsightsRow: View {
    var body: some View {
        PlanPageRow(
            title: "Pace Insights",
            subtitle: "Estimated finish and training paces",
            icon: .tempo
        )
    }
}

/// A row that opens one of the plan's reference pages.
struct PlanPageRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: StrideIconName

    var body: some View {
        HStack(spacing: 12) {
            StrideIcon(name: icon, size: 16, color: .brand, strokeWeight: 2)
                .frame(width: 32, height: 32)
                .background(Color.brand.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.dsSubhead.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StrideIcon(name: .chevronRight, size: 12, color: .secondary, strokeWeight: 2.4)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .strideCard()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct PaceInsightsCard: View {
    let plan: TrainingPlan
    /// Recent runs and the profile, read through `RaceDayPlan.currentVDOT` — the same
    /// fitness the race countdown and Progress' insights predict from, so the three
    /// screens give one finish time and one set of paces.
    let runs: [RunWorkout]
    let profile: UserProfile?
    @Environment(AppSettings.self) private var appSettings

    private var measuredVDOT: Double? {
        RaceDayPlan.currentVDOT(runs: runs, profile: profile)
    }

    /// Whether a logged run gives a fitness figure yet. Passes no profile, so the runner's own
    /// 5K estimate (`currentVDOT`'s fallback) doesn't count as measured.
    private var hasMeasuredFitness: Bool { RaceDayPlan.currentVDOT(runs: runs, profile: nil) != nil }

    private var currentVDOT: Double {
        if let measuredVDOT { return measuredVDOT }
        return PaceCalculatorService.vdot(
            distanceMeters: plan.effectiveRaceDistanceMeters,
            timeSeconds: plan.goalTimeSeconds
        )
    }

    private var estimatedTime: TimeInterval {
        PaceCalculatorService.predictedTime(vdot: currentVDOT, distanceMeters: plan.effectiveRaceDistanceMeters)
    }

    private var trainingPaces: TrainingPaces {
        PaceCalculatorService.trainingPaces(forVDOT: currentVDOT)
    }

    private var timeDiff: TimeInterval { estimatedTime - plan.goalTimeSeconds }

    private var statusColor: Color {
        if abs(timeDiff) < 30 { return .brand }
        return timeDiff > 0 ? .warning : .success
    }

    /// Before any run is logged, `currentVDOT` is derived from the plan's own goal time, so
    /// the estimate and the goal are the same number by construction. Claiming "On track for
    /// goal" off that is a tautology dressed as a verdict (S12) — say where the number comes
    /// from instead, and only compare once there is something to compare against.
    private var statusText: String {
        if !hasMeasuredFitness { return "Starting projection" }
        if abs(timeDiff) < 30 { return "On track for goal" }
        let formatted = abs(timeDiff).durationString
        return timeDiff > 0 ? "\(formatted) behind goal" : "\(formatted) ahead of goal"
    }

    @ViewBuilder
    private var statusIconView: some View {
        if timeDiff > 0 && abs(timeDiff) >= 30 {
            StrideIcon(name: .flag, size: 14, color: statusColor, strokeWeight: 2)
        } else {
            ZStack {
                Circle().fill(statusColor).frame(width: 16, height: 16)
                StrideIcon(name: .check, size: 8, color: .onFill, strokeWeight: 2.5)
            }
        }
    }

    /// Whether the computed VDOT falls within a realistic human range (~20–85).
    /// Outside this range the goal time stored on the plan is unreliable and
    /// training paces should not be shown.
    private var isVDOTReliable: Bool {
        (20...85).contains(currentVDOT)
    }

    private func paceRangeString(_ range: ClosedRange<Double>) -> String {
        "\(stripUnit(range.lowerBound)) – \(stripUnit(range.upperBound))"
    }

    private func paceString(_ secs: Double) -> String {
        stripUnit(secs)
    }

    private func stripUnit(_ secs: Double) -> String {
        guard secs > 0 && secs.isFinite else { return "--:--" }
        return secs.paceString(unit: appSettings.unitPreference)
            .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimated Finish")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                    Text(isVDOTReliable ? estimatedTime.durationString : "--:--")
                        .font(.metricSmall)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Goal")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                    Text(plan.goalTimeSeconds.durationString)
                        .font(.bodyStrong)
                }
            }

            HStack(spacing: 6) {
                if isVDOTReliable {
                    // The status colour stays in the glyph; the words stay readable
                    // (brand and warning are too light for caption text).
                    statusIconView
                    Text(statusText)
                        .font(.dsCaption.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !hasMeasuredFitness {
                        Text("· Log a quality run to track against it")
                            .font(.dsCaption)
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                } else {
                    StrideIcon(name: .chart, size: 14, color: .secondary, strokeWeight: 1.8)
                    Text(hasMeasuredFitness ? "Analyzing current pace…" : "Log a quality run to calibrate paces")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(spacing: 12) {
                if isVDOTReliable {
                    PaceRow(label: "Easy",       zone: .easy,
                            value: paceRangeString(trainingPaces.easyRange))
                    PaceRow(label: "Marathon",   zone: .marathon,
                            value: paceString(trainingPaces.marathon))
                    PaceRow(label: "Tempo",      zone: .tempo,
                            value: paceString(trainingPaces.threshold))
                    PaceRow(label: "Interval",   zone: .interval,
                            value: paceString(trainingPaces.interval))
                    PaceRow(label: "Repetition", zone: .maxEffort,
                            value: paceString(trainingPaces.repetition))
                } else {
                    Text("Analyzing current pace…")
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .strideCard()
    }
}

// MARK: - Pace Row

struct PaceRow: View {
    let label: String
    let zone: PaceZone
    let value: String
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: AppRadius.micro)
                .fill(zone.color)
                .frame(width: 3, height: 22)

            Text(label)
                .font(.dsSubhead.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.dsSubhead.weight(.semibold).monospacedDigit())
                Text(appSettings.unitPreference.paceLabel)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
