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
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))

                if insights.recentTempoCount == 0 {
                    Text("This is your first tempo run — keep it up to track pace trends.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private func tempoInsightPaceRow(_ insights: TempoInsights) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TEMPO PACE")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(insights.achievedPaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .kerning(-0.5)

                if let prev = insights.previousBestTempoSecondsPerKm {
                    let delta = prev - insights.achievedPaceSecondsPerKm
                    let isNew = delta > 1
                    HStack(spacing: 4) {
                        Image(systemName: isNew ? "arrow.up.circle.fill" : (delta < -1 ? "arrow.down.circle.fill" : "minus.circle.fill"))
                            .font(.system(size: 10))
                        Text(isNew
                             ? "New best"
                             : (delta < -1
                                ? "\(Int(abs(delta)))s slower than best"
                                : "Matches best"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(isNew ? Color.success : (delta < -1 ? Color.destructive : Color.secondary))
                }
            }
            Spacer()
            if let target = insights.targetThresholdSecondsPerKm {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("TARGET")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    Text(target.paceString(unit: appSettings.unitPreference))
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
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
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(label).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
    }

    private func tempoInsightVDOTRow(_ insights: TempoInsights) -> some View {
        HStack(spacing: 0) {
            if let vdot = insights.derivedVDOT {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VDOT THIS RUN")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", vdot))
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        if let prev = insights.previousVDOT {
                            let delta = vdot - prev
                            Text(delta >= 0
                                 ? String(format: "+%.1f", delta)
                                 : String(format: "%.1f", delta))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(delta >= 0.3 ? Color.success : (delta <= -0.3 ? Color.destructive : Color.secondary))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let prev = insights.previousVDOT {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("PREV VDOT")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f", prev))
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
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
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "±%.0fs/km", stdDevSeconds))
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    Text("std dev")
                        .font(.system(size: 11))
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
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(color.opacity(0.1), in: Capsule())
        }
    }
}
