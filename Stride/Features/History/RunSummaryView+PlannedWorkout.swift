import SwiftUI

// Part of `RunSummaryView` (D1).
// The planned-workout section: what the plan asked for, what the run delivered, and how
// far apart the two were.

extension RunSummaryView {

    // MARK: Planned Workout Section

    @ViewBuilder
    var plannedWorkoutSection: some View {
        if let scheduled = matchedScheduled {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: "Planned Workout")

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(scheduled.workoutType.color)
                            .frame(width: 8, height: 8)
                        Text(scheduled.workoutType.localizedName)
                            .font(.dsSubhead.weight(.bold))
                        Spacer()
                        Text(scheduled.scheduledDate.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.dsCaption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    if scheduled.targetDistanceMeters != nil || scheduled.targetPaceRange != nil {
                        HStack(spacing: 8) {
                            if let dist = scheduled.targetDistanceMeters {
                                let converted = appSettings.unitPreference == .imperial ? dist / 1_609.344 : dist / 1_000
                                plannedChip(icon: "arrow.right", text: String(format: "%.1f %@", converted, appSettings.unitPreference.distanceLabel))
                            }
                            if let range = scheduled.targetPaceRange {
                                let lo = range.lowerBound.paceString(unit: appSettings.unitPreference)
                                    .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: "")
                                let hi = range.upperBound.paceString(unit: appSettings.unitPreference)
                                plannedChip(icon: "speedometer", text: "\(lo)–\(hi)")
                            }
                        }
                    }

                    if let notes = scheduled.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(notes)
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let hasComparison = scheduled.targetDistanceMeters != nil || scheduled.targetPaceRange != nil
                    if hasComparison {
                        Divider().padding(.vertical, 2)

                        if let targetDist = scheduled.targetDistanceMeters {
                            let converted = appSettings.unitPreference == .imperial ? targetDist / 1_609.344 : targetDist / 1_000
                            planComparisonRow(
                                label: "Distance",
                                planned: String(format: "%.2f %@", converted, appSettings.unitPreference.distanceLabel),
                                actual: "\(titleMetric.value) \(titleMetric.unit)",
                                status: distanceStatus(actual: workout.distanceMeters, target: targetDist)
                            )
                        }

                        if let range = scheduled.targetPaceRange {
                            let actual = workout.averagePaceSecondsPerKm
                            let lo = range.lowerBound.paceString(unit: appSettings.unitPreference)
                                .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: "")
                            let hi = range.upperBound.paceString(unit: appSettings.unitPreference)
                            planComparisonRow(
                                label: "Avg Pace",
                                planned: "\(lo)–\(hi)",
                                actual: actual.paceString(unit: appSettings.unitPreference),
                                status: paceStatus(actual: actual, target: range)
                            )
                        }
                    }
                }
                .padding(14)
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
            }
        } else if let avg = workout.averageHeartRate, avg >= 155 {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.warning)
                        .frame(width: 24, height: 24)
                    Image(systemName: "exclamationmark")
                        .font(.dsCaption.weight(.bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Effort higher than expected")
                        .font(.dsFootnote.weight(.bold))
                        .foregroundStyle(.warning)
                    Text("HR averaged \(Int(avg)) bpm for this \(workout.workoutType.losplayName.lowercased()) effort.")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.warning.opacity(0.22), lineWidth: 0.5))
        }
    }

    private func plannedChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.dsCaption2.weight(.semibold))
            Text(text)
                .font(.dsCaption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.surfaceTertiary, in: Capsule())
    }

    private func planComparisonRow(label: String, planned: String, actual: String, status: PaceStatus) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.dsCaption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)
            Text(planned)
                .font(.dsCaption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.dsCaption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(actual)
                .font(.dsCaption.weight(.bold).monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Image(systemName: status.icon)
                    .font(.dsCaption2.weight(.bold))
                Text(status.label)
                    .font(.dsCaption2.weight(.bold))
            }
            .foregroundStyle(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.1), in: Capsule())
        }
    }

    private func distanceStatus(actual: Double, target: Double) -> PaceStatus {
        let ratio = actual / target
        if ratio > 1.05 {
            return PaceStatus(label: "Exceeded", icon: "arrow.up.circle.fill", color: .brand)
        } else if ratio >= 0.97 {
            return PaceStatus(label: "Completed", icon: "checkmark.circle.fill", color: .success)
        } else if ratio >= 0.90 {
            return PaceStatus(label: "Close", icon: "minus.circle.fill", color: .warning)
        } else {
            return PaceStatus(label: "Short", icon: "arrow.down.circle.fill", color: .destructive)
        }
    }

    private struct PaceStatus {
        let label: String
        let icon: String
        let color: Color
    }

    private func paceStatus(actual: Double, target: ClosedRange<Double>) -> PaceStatus {
        if target.contains(actual) {
            return PaceStatus(label: "On target", icon: "checkmark.circle.fill", color: .success)
        }
        let margin = (target.upperBound - target.lowerBound) * 0.1 + target.upperBound * 0.05
        if actual <= target.upperBound + margin && actual >= target.lowerBound - margin {
            return PaceStatus(label: "Slightly off target", icon: "exclamationmark.circle.fill", color: .warning)
        }
        if actual < target.lowerBound {
            return PaceStatus(label: "Too fast", icon: "bolt.fill", color: .warning)
        }
        return PaceStatus(label: "Too slow", icon: "tortoise.fill", color: .destructive)
    }
}
