import SwiftUI

/// Compact card showing a scheduled workout — used on the Dashboard.
struct WorkoutCardView: View {
    let workout: ScheduledWorkout
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        HStack(spacing: 14) {
            typeIcon

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(workout.workoutType.localizedName)
                        .font(.bodyStrong)
                    if workout.isCompleted {
                        ZStack {
                            Circle()
                                .fill(Color.success)
                                .frame(width: 16, height: 16)
                            StrideIcon(name: .check, size: 9, color: .white, strokeWeight: 3)
                        }
                    }
                }

                if let dist = workout.targetDistanceMeters {
                    HStack(spacing: 6) {
                        Text(dist.distanceString(unit: appSettings.unitPreference))
                        if let range = workout.targetPaceRange {
                            Text("·")
                            Text(
                                "\(range.lowerBound.paceString(unit: appSettings.unitPreference))"
                                + " – "
                                + "\(range.upperBound.paceString(unit: appSettings.unitPreference))"
                            )
                        }
                    }
                    .font(.dsFootnote.weight(.medium).monospaced())
                    .foregroundStyle(.secondary)
                }

                if let notes = workout.notes {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
            StrideIcon(name: .chevronRight, size: 12, color: Color.secondary.opacity(0.5), strokeWeight: 2)
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.md)
    }

    private var typeIcon: some View {
        ZStack {
            Circle()
                .fill(workout.workoutType.color.opacity(0.18))
                .frame(width: 44, height: 44)
            StrideIcon(name: workout.workoutType.strideIcon, size: 22, color: workout.workoutType.color, strokeWeight: 2.0)
        }
    }
}
