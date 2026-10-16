import SwiftUI

// Part of `RunSummaryView` (D1).
// The pace-insights card shown for tempo and race runs: how this effort compares with
// the previous best, what it implies for VDOT, and how even the splits were.
// The maths behind it is `WorkoutAnalyticsService`; this is only its presentation.

extension RunSummaryView {

    // MARK: Pace insights section (tempo runs)

    @ViewBuilder
    var paceInsightsSection: some View {
        if let insights = tempoInsights {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: "Pace Insights")

                VStack(spacing: 10) {
                    tempoInsightPaceRow(insights)
                    if insights.derivedVDOT != nil || insights.previousVDOT != nil {
                        Divider().padding(.horizontal, -2)
                        tempoInsightVDOTRow(insights)
                    }
                    if let consistency = insights.splitConsistencySeconds {
                        Divider().padding(.horizontal, -2)
                        tempoInsightConsistencyRow(consistency)
                    }
                }
                .padding(14)
                .strideCard()

                if insights.recentTempoCount == 0 {
                    Text("This is your first tempo run — keep it up to track pace trends.")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppSpacing.xs)
                }
            }
        }
    }

    private func tempoInsightPaceRow(_ insights: TempoInsights) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TEMPO PACE")
                    .font(.dsCaption2.weight(.bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(insights.achievedPaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                    .font(.dsTitle2.weight(.semibold).monospacedDigit())
                    .kerning(-0.5)

                if let prev = insights.previousBestTempoSecondsPerKm {
                    let delta = prev - insights.achievedPaceSecondsPerKm
                    let isNew = delta > 1
                    HStack(spacing: 4) {
                        Image(systemName: isNew ? "arrow.up.circle.fill" : (delta < -1 ? "arrow.down.circle.fill" : "minus.circle.fill"))
                            .font(.dsCaption2)
                        Text(isNew
                             ? "New best"
                             : (delta < -1
                                ? "\(Int(abs(delta)))s slower than best"
                                : "Matches best"))
                            .font(.dsCaption.weight(.semibold))
                    }
                    .foregroundStyle(isNew ? Color.success : (delta < -1 ? Color.destructive : Color.secondary))
                }
            }
            Spacer()
            if let target = insights.targetThresholdSecondsPerKm {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("TARGET")
                        .font(.dsCaption2.weight(.bold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    Text(target.paceString(unit: appSettings.unitPreference))
                        .font(.dsCallout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    tempoTargetStatusChip(actual: insights.achievedPaceSecondsPerKm, target: target)
                }
            }
        }
    }

    private func tempoTargetStatusChip(actual: Double, target: Double) -> some View {
        let margin = target * 0.04
        let (label, icon, color): (String, String, Color) = {
            if actual <= target - margin {
                return ("Exceeded", "bolt.fill", .brand)
            } else if actual <= target + margin {
                return ("On target", "checkmark.circle.fill", .success)
            } else if actual <= target + margin * 3 {
                return ("Slightly slow", "exclamationmark.circle.fill", .warning)
            } else {
                return ("Off target", "tortoise.fill", .destructive)
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.dsCaption2.weight(.bold))
            Text(label).font(.dsCaption2.weight(.bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(color.opacity(0.1), in: Capsule())
    }

    private func tempoInsightVDOTRow(_ insights: TempoInsights) -> some View {
        HStack(spacing: 0) {
            if let vdot = insights.derivedVDOT {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VDOT THIS RUN")
                        .font(.dsCaption2.weight(.bold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", vdot))
                            .font(.dsTitle3.monospacedDigit())
                        if let prev = insights.previousVDOT {
                            let delta = vdot - prev
                            Text(delta >= 0
                                 ? String(format: "+%.1f", delta)
                                 : String(format: "%.1f", delta))
                                .font(.dsCaption.weight(.bold))
                                .foregroundStyle(delta >= 0.3 ? Color.success : (delta <= -0.3 ? Color.destructive : Color.secondary))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let prev = insights.previousVDOT {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("PREV VDOT")
                        .font(.dsCaption2.weight(.bold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f", prev))
                        .font(.dsTitle3.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func tempoInsightConsistencyRow(_ stdDevSeconds: Double) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("SPLIT CONSISTENCY")
                    .font(.dsCaption2.weight(.bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "±%.0fs/km", stdDevSeconds))
                        .font(.dsHeadline.monospacedDigit())
                    Text("std dev")
                        .font(.dsCaption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            let (label, color): (String, Color) = {
                if stdDevSeconds <= 5 { return ("Excellent", .success) }
                if stdDevSeconds <= 12 { return ("Good", .brand) }
                if stdDevSeconds <= 20 { return ("Variable", .warning) }
                return ("Uneven", .destructive)
            }()
            Text(label)
                .font(.dsCaption.weight(.bold))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(color.opacity(0.1), in: Capsule())
        }
    }
}
