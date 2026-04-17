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
                    Text(workout.workoutType.displayName)
                        .font(.bodyStrong)
                    if workout.isCompleted {
                        ZStack {
                            Circle()
                                .fill(Color.success)
                                .frame(width: 16, height: 16)
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
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
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
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
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
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
